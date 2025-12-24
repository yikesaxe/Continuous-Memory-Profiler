#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <unistd.h>
#include <stdatomic.h>
#include <string.h>
#include <math.h>
#include <pthread.h>
#include <errno.h>
#include <stdint.h>
#include <malloc.h>
#include "sampler.h"

// --- Global State ---

static SamplingScheme g_scheme = SCHEME_NONE;
static char *g_stats_file = NULL;
static long g_poisson_mean = DEFAULT_POISSON_MEAN;
static Stats g_stats = {0};
static bool g_combined_mode = false;
static bool g_timing_enabled = false; // NEW: Enable timing measurements

// Timing statistics
typedef struct {
    atomic_uint_least64_t total_calls;
    atomic_uint_least64_t total_cycles;
    atomic_uint_least64_t min_cycles;
    atomic_uint_least64_t max_cycles;
    atomic_uint_least64_t samples_taken;
} TimingStats;

static TimingStats g_timing_poisson = {0, 0, UINT64_MAX, 0, 0};
static TimingStats g_timing_hash = {0, 0, UINT64_MAX, 0, 0};
static TimingStats g_timing_poisson_free = {0, 0, UINT64_MAX, 0, 0};
static TimingStats g_timing_hash_free = {0, 0, UINT64_MAX, 0, 0};

// High-resolution cycle counter
#if defined(__x86_64__) || defined(__i386__)
static inline uint64_t read_cycles(void) {
    unsigned int lo, hi;
    __asm__ __volatile__ ("rdtsc" : "=a" (lo), "=d" (hi));
    return ((uint64_t)hi << 32) | lo;
}
#elif defined(__aarch64__)
static inline uint64_t read_cycles(void) {
    uint64_t val;
    __asm__ __volatile__("mrs %0, cntvct_el0" : "=r" (val));
    return val;
}
#else
// Fallback to nanoseconds
static inline uint64_t read_cycles(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}
#endif

// Record timing measurement
static inline void record_timing(TimingStats *stats, uint64_t cycles, bool sampled) {
    atomic_fetch_add(&stats->total_calls, 1);
    atomic_fetch_add(&stats->total_cycles, cycles);
    if (sampled) {
        atomic_fetch_add(&stats->samples_taken, 1);
    }
    
    // Update min (lock-free, may have races but close enough)
    uint64_t current_min = atomic_load(&stats->min_cycles);
    while (cycles < current_min) {
        if (atomic_compare_exchange_weak(&stats->min_cycles, &current_min, cycles)) {
            break;
        }
    }
    
    // Update max
    uint64_t current_max = atomic_load(&stats->max_cycles);
    while (cycles > current_max) {
        if (atomic_compare_exchange_weak(&stats->max_cycles, &current_max, cycles)) {
            break;
        }
    }
}

// Page tracking bitmaps for PAGE_HASH approximation
#define PAGE_BITMAP_SIZE 4096
static atomic_uint_least64_t g_page_seen_bits[PAGE_BITMAP_SIZE / 64];
static atomic_uint_least64_t g_page_sampled_bits[PAGE_BITMAP_SIZE / 64];

// Function pointers to real allocators
static void *(*real_malloc)(size_t) = NULL;
static void (*real_free)(void *) = NULL;

// Initialization state
static atomic_bool g_initialized = false;
static pthread_mutex_t g_init_lock = PTHREAD_MUTEX_INITIALIZER;

// Thread-local recursion guard
static __thread bool t_in_wrapper = false;

// Hash sets to track sampled addresses
#define SAMPLED_SET_SIZE 1048576
static void *g_sampled_addrs_poisson[SAMPLED_SET_SIZE] = {NULL};
static void *g_sampled_addrs_hash[SAMPLED_SET_SIZE] = {NULL};
static pthread_mutex_t g_sampled_lock_poisson = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_sampled_lock_hash = PTHREAD_MUTEX_INITIALIZER;

static void mark_sampled_poisson(void *ptr) {
    pthread_mutex_lock(&g_sampled_lock_poisson);
    size_t idx = ((uintptr_t)ptr >> 4) % SAMPLED_SET_SIZE;
    for (size_t i = 0; i < 100; i++) {
        size_t probe = (idx + i) % SAMPLED_SET_SIZE;
        if (g_sampled_addrs_poisson[probe] == NULL || g_sampled_addrs_poisson[probe] == ptr) {
            g_sampled_addrs_poisson[probe] = ptr;
            break;
        }
    }
    pthread_mutex_unlock(&g_sampled_lock_poisson);
}

static void mark_sampled_hash(void *ptr) {
    pthread_mutex_lock(&g_sampled_lock_hash);
    size_t idx = ((uintptr_t)ptr >> 4) % SAMPLED_SET_SIZE;
    for (size_t i = 0; i < 100; i++) {
        size_t probe = (idx + i) % SAMPLED_SET_SIZE;
        if (g_sampled_addrs_hash[probe] == NULL || g_sampled_addrs_hash[probe] == ptr) {
            g_sampled_addrs_hash[probe] = ptr;
            break;
        }
    }
    pthread_mutex_unlock(&g_sampled_lock_hash);
}

static bool was_sampled_poisson(void *ptr) {
    pthread_mutex_lock(&g_sampled_lock_poisson);
    size_t idx = ((uintptr_t)ptr >> 4) % SAMPLED_SET_SIZE;
    bool found = false;
    for (size_t i = 0; i < 100; i++) {
        size_t probe = (idx + i) % SAMPLED_SET_SIZE;
        if (g_sampled_addrs_poisson[probe] == ptr) {
            found = true;
            g_sampled_addrs_poisson[probe] = NULL;
            break;
        }
        if (g_sampled_addrs_poisson[probe] == NULL) break;
    }
    pthread_mutex_unlock(&g_sampled_lock_poisson);
    return found;
}

static bool was_sampled_hash(void *ptr) {
    uintptr_t h = (uintptr_t)ptr;
    h ^= h >> 12;
    h ^= h << 25;
    h ^= h >> 27;
    return (h & DEFAULT_HASH_MASK) == 0;
}

// Thread-local Sampler State
typedef struct {
    int64_t pois_bytes_until_next;
    bool pois_bytes_inited;
    int64_t hash_running_bytes;
    uint64_t rng_state;
    bool rng_init;
} ThreadSamplerState;

static __thread ThreadSamplerState tstate = { 
    .pois_bytes_until_next = 0, 
    .pois_bytes_inited = false,
    .hash_running_bytes = 0,
    .rng_state = 0xDEADBEEFCAFEBABE,
    .rng_init = false 
};

// --- Helpers ---

static uint64_t xorshift64(uint64_t *s) {
    uint64_t x = *s;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    *s = x;
    return x * 0x2545F4914F6CDD1DULL;
}

static void init_rng() {
    if (!tstate.rng_init) {
        tstate.rng_state = (uint64_t)&tstate ^ (uint64_t)time(NULL) ^ (uintptr_t)pthread_self();
        if (tstate.rng_state == 0) tstate.rng_state = 0xCAFEBABE;
        tstate.rng_init = true;
    }
}

static long draw_geometric_bytes(long mean_bytes) {
    if (!tstate.rng_init) init_rng();
    
    double u = (xorshift64(&tstate.rng_state) >> 11) * 0x1.0p-53;
    if (u <= 0.0) u = 1e-12;
    
    return (long)(-log(u) * mean_bytes);
}

// Initialize real function pointers and configuration
static void init_sampler() {
    if (atomic_load(&g_initialized)) return;

    pthread_mutex_lock(&g_init_lock);
    if (!atomic_load(&g_initialized)) {
        real_malloc = dlsym(RTLD_NEXT, "malloc");
        real_free = dlsym(RTLD_NEXT, "free");

        if (!real_malloc || !real_free) {
            fprintf(stderr, "Error: Could not resolve real allocator functions: %s\n", dlerror());
            abort();
        }

        // Parse Env Vars
        char *env_scheme = getenv("SAMPLER_SCHEME");
        if (env_scheme) {
            if (strcmp(env_scheme, "COMBINED") == 0) {
                g_combined_mode = true;
                g_scheme = SCHEME_NONE;
            } else if (strcmp(env_scheme, "STATELESS_HASH") == 0) g_scheme = SCHEME_STATELESS_HASH;
            else if (strcmp(env_scheme, "POISSON") == 0) g_scheme = SCHEME_POISSON;
            else if (strcmp(env_scheme, "NONE") == 0) g_scheme = SCHEME_NONE;
            else if (strcmp(env_scheme, "HYBRID") == 0) g_scheme = SCHEME_HYBRID_SMALL_POISSON_LARGE_HASH;
            else if (strcmp(env_scheme, "PAGE_HASH") == 0) g_scheme = SCHEME_PAGE_HASH;
            else g_scheme = SCHEME_NONE;
        }

        g_stats_file = getenv("SAMPLER_STATS_FILE");
        
        char *env_mean = getenv("SAMPLER_POISSON_MEAN_BYTES");
        if (env_mean) {
            long val = atol(env_mean);
            if (val > 0) g_poisson_mean = val;
        }
        
        // NEW: Check if timing is enabled
        char *env_timing = getenv("SAMPLER_TIMING");
        if (env_timing && strcmp(env_timing, "1") == 0) {
            g_timing_enabled = true;
            fprintf(stderr, "[SAMPLER] Timing measurements enabled\n");
        }

        atomic_store(&g_initialized, true);
    }
    pthread_mutex_unlock(&g_init_lock);
}

// --- Sampling Logic ---

static inline uint64_t hash64(uint64_t x) {
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    return x * 0x2545F4914F6CDD1DULL;
}

static bool should_sample_alloc_page_hash(void *real_ptr, size_t size) {
    (void)size;
    uintptr_t addr = (uintptr_t)real_ptr;
    uintptr_t page = addr >> 12;
    uint64_t h = hash64(page);
    return (h & DEFAULT_HASH_MASK) == 0;
}

static size_t sample_poisson(size_t size) {
    if (tstate.pois_bytes_until_next < 0) {
        return 0;
    }
    int64_t remaining_bytes = tstate.pois_bytes_until_next;

    if (!tstate.pois_bytes_inited) {
        remaining_bytes -= draw_geometric_bytes(g_poisson_mean);
        tstate.pois_bytes_inited = true;
        if (remaining_bytes < 0) {
            tstate.pois_bytes_until_next = remaining_bytes; 
            return 0;
        }
    }

    size_t nsamples = remaining_bytes / g_poisson_mean;
    remaining_bytes = remaining_bytes % g_poisson_mean;

    do {
        remaining_bytes -= draw_geometric_bytes(g_poisson_mean);
        nsamples++;
    } while (remaining_bytes >= 0);

    tstate.pois_bytes_until_next = remaining_bytes;
    return nsamples * g_poisson_mean;
}

static size_t sample_hash(void *ptr) {
    uintptr_t h = (uintptr_t)ptr;
    h ^= h >> 12;
    h ^= h << 25;
    h ^= h >> 27;
    if ((h & DEFAULT_HASH_MASK) == 0) {
        size_t reported = tstate.hash_running_bytes;
        tstate.hash_running_bytes = 0;
        return reported;
    }
    return 0;
}

static size_t sample(void *ptr, size_t size) {
    size_t reported_size = 0;
    switch (g_scheme) {
        case SCHEME_NONE:
            return size;
        case SCHEME_STATELESS_HASH:
            return sample_hash(ptr);
        case SCHEME_POISSON:
            return sample_poisson(size);
        default:
            return reported_size;
    }
}

// --- Allocator Interceptors ---

void *malloc(size_t size) {
    if (t_in_wrapper) return NULL; 

    if (!atomic_load(&g_initialized)) init_sampler();

    t_in_wrapper = true;

    struct timespec ts;
    void *ptr = real_malloc(size);
    clock_gettime(CLOCK_REALTIME, &ts);

    if (!ptr) {
        t_in_wrapper = false;
        return NULL;
    }
    
    if (g_combined_mode) {
        // COMBINED MODE: Evaluate both schemes and log everything
        tstate.pois_bytes_until_next += size;
        tstate.hash_running_bytes += size;
        
        // Evaluate Poisson sampling WITH TIMING
        uint64_t start_pois = g_timing_enabled ? read_cycles() : 0;
        size_t pois_size = sample_poisson(size);
        uint64_t end_pois = g_timing_enabled ? read_cycles() : 0;
        bool pois_tracked = (pois_size > 0);
        
        if (g_timing_enabled) {
            record_timing(&g_timing_poisson, end_pois - start_pois, pois_tracked);
        }
        
        if (pois_tracked) {
            mark_sampled_poisson(ptr);
        }
        
        // Evaluate Hash sampling WITH TIMING
        uint64_t start_hash = g_timing_enabled ? read_cycles() : 0;
        size_t hash_size = sample_hash(ptr);
        uint64_t end_hash = g_timing_enabled ? read_cycles() : 0;
        bool hash_tracked = (hash_size > 0);
        
        if (g_timing_enabled) {
            record_timing(&g_timing_hash, end_hash - start_hash, hash_tracked);
        }
        
        if (hash_tracked) {
            mark_sampled_hash(ptr);
        }
        
        // Log format: MALLOC, timestamp, address, actual_size, poisson_tracked, poisson_size, hash_tracked, hash_size
        printf("MALLOC, %ld.%09ld, %p, %zu, %d, %zu, %d, %zu\n",
            ts.tv_sec, ts.tv_nsec,
            ptr, size,
            pois_tracked ? 1 : 0, pois_size,
            hash_tracked ? 1 : 0, hash_size
        );
    } else {
        // LEGACY MODE: Single scheme
        tstate.hash_running_bytes += size;
        tstate.pois_bytes_until_next += size;
        
        uint64_t start = g_timing_enabled ? read_cycles() : 0;
        size_t reported_size = sample(ptr, size);
        uint64_t end = g_timing_enabled ? read_cycles() : 0;
        
        if (g_timing_enabled) {
            if (g_scheme == SCHEME_POISSON) {
                record_timing(&g_timing_poisson, end - start, reported_size > 0);
            } else if (g_scheme == SCHEME_STATELESS_HASH) {
                record_timing(&g_timing_hash, end - start, reported_size > 0);
            }
        }
        
        if (reported_size) {
            if (g_scheme == SCHEME_POISSON) {
                mark_sampled_poisson(ptr);
            } else if (g_scheme == SCHEME_STATELESS_HASH) {
                mark_sampled_hash(ptr);
            }
            
            printf("MALLOC, %ld.%09ld, %p, %zu, %zu\n",
                ts.tv_sec, ts.tv_nsec,
                ptr, size, reported_size
            );
        }
    }
    
    t_in_wrapper = false;
    return ptr;
}

void free(void *ptr) {
    if (!ptr) return;
    if (t_in_wrapper) return; 

    if (!atomic_load(&g_initialized)) init_sampler();
    
    t_in_wrapper = true;

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    
    if (g_combined_mode) {
        // Time Poisson free decision
        uint64_t start_pois = g_timing_enabled ? read_cycles() : 0;
        bool pois_tracked = was_sampled_poisson(ptr);
        uint64_t end_pois = g_timing_enabled ? read_cycles() : 0;
        
        if (g_timing_enabled) {
            record_timing(&g_timing_poisson_free, end_pois - start_pois, pois_tracked);
        }
        
        // Time Hash free decision
        uint64_t start_hash = g_timing_enabled ? read_cycles() : 0;
        bool hash_tracked = was_sampled_hash(ptr);
        uint64_t end_hash = g_timing_enabled ? read_cycles() : 0;
        
        if (g_timing_enabled) {
            record_timing(&g_timing_hash_free, end_hash - start_hash, hash_tracked);
        }
        
        printf("FREE, %ld.%09ld, %p, -1, %d, -1, %d, -1\n",
            ts.tv_sec, ts.tv_nsec,
            ptr,
            pois_tracked ? 1 : 0,
            hash_tracked ? 1 : 0
        );

    } else {
        bool should_log = false;
        uint64_t start = g_timing_enabled ? read_cycles() : 0;
        
        if (g_scheme == SCHEME_NONE) {
            should_log = true;
        } else if (g_scheme == SCHEME_POISSON) {
            should_log = was_sampled_poisson(ptr);
        } else if (g_scheme == SCHEME_STATELESS_HASH) {
            should_log = was_sampled_hash(ptr);
        }
        
        uint64_t end = g_timing_enabled ? read_cycles() : 0;
        
        if (g_timing_enabled) {
            if (g_scheme == SCHEME_POISSON) {
                record_timing(&g_timing_poisson_free, end - start, should_log);
            } else if (g_scheme == SCHEME_STATELESS_HASH) {
                record_timing(&g_timing_hash_free, end - start, should_log);
            }
        }
        
        if (should_log) {
            printf("FREE, %ld.%09ld, %p, -1\n",
                ts.tv_sec, ts.tv_nsec,
                ptr
            );
        }
    }
    
    real_free(ptr);

    t_in_wrapper = false;
}

// Print timing statistics at exit
__attribute__((destructor))
static void print_timing_stats(void) {
    if (!g_timing_enabled) return;
    
    fprintf(stderr, "\n========================================\n");
    fprintf(stderr, "SAMPLING DECISION TIMING STATISTICS\n");
    fprintf(stderr, "========================================\n");
    
    #if defined(__x86_64__) || defined(__i386__)
    fprintf(stderr, "Platform: x86_64 (RDTSC cycles)\n");
    #elif defined(__aarch64__)
    fprintf(stderr, "Platform: ARM64 (CNTVCT cycles)\n");
    #else
    fprintf(stderr, "Platform: Generic (nanoseconds)\n");
    #endif
    
    if (atomic_load(&g_timing_poisson.total_calls) > 0) {
        uint64_t calls = atomic_load(&g_timing_poisson.total_calls);
        uint64_t cycles = atomic_load(&g_timing_poisson.total_cycles);
        uint64_t samples = atomic_load(&g_timing_poisson.samples_taken);
        uint64_t min_cyc = atomic_load(&g_timing_poisson.min_cycles);
        uint64_t max_cyc = atomic_load(&g_timing_poisson.max_cycles);
        double avg = (double)cycles / calls;
        double sample_rate = (double)samples / calls * 100.0;
        
        fprintf(stderr, "\nPoisson Sampling:\n");
        fprintf(stderr, "  Total decisions:  %lu\n", calls);
        fprintf(stderr, "  Samples taken:    %lu (%.2f%%)\n", samples, sample_rate);
        fprintf(stderr, "  Avg cycles:       %.4f\n", avg);
        fprintf(stderr, "  Min cycles:       %lu\n", min_cyc);
        fprintf(stderr, "  Max cycles:       %lu\n", max_cyc);
        fprintf(stderr, "  Total cycles:     %lu\n", cycles);
    }
    
    if (atomic_load(&g_timing_hash.total_calls) > 0) {
        uint64_t calls = atomic_load(&g_timing_hash.total_calls);
        uint64_t cycles = atomic_load(&g_timing_hash.total_cycles);
        uint64_t samples = atomic_load(&g_timing_hash.samples_taken);
        uint64_t min_cyc = atomic_load(&g_timing_hash.min_cycles);
        uint64_t max_cyc = atomic_load(&g_timing_hash.max_cycles);
        double avg = (double)cycles / calls;
        double sample_rate = (double)samples / calls * 100.0;
        
        fprintf(stderr, "\nHash Sampling:\n");
        fprintf(stderr, "  Total decisions:  %lu\n", calls);
        fprintf(stderr, "  Samples taken:    %lu (%.2f%%)\n", samples, sample_rate);
        fprintf(stderr, "  Avg cycles:       %.4f\n", avg);
        fprintf(stderr, "  Min cycles:       %lu\n", min_cyc);
        fprintf(stderr, "  Max cycles:       %lu\n", max_cyc);
        fprintf(stderr, "  Total cycles:     %lu\n", cycles);
    }
    
    // Comparison if both were measured
    if (atomic_load(&g_timing_poisson.total_calls) > 0 && 
        atomic_load(&g_timing_hash.total_calls) > 0) {
        uint64_t pois_cycles = atomic_load(&g_timing_poisson.total_cycles);
        uint64_t hash_cycles = atomic_load(&g_timing_hash.total_cycles);
        uint64_t pois_calls = atomic_load(&g_timing_poisson.total_calls);
        uint64_t hash_calls = atomic_load(&g_timing_hash.total_calls);
        
        double pois_avg = (double)pois_cycles / pois_calls;
        double hash_avg = (double)hash_cycles / hash_calls;
        
        fprintf(stderr, "\nMalloc Overhead Comparison:\n");
        fprintf(stderr, "  Hash vs Poisson speedup: %.2fx\n", pois_avg / hash_avg);
        fprintf(stderr, "  Absolute difference:     %.4f cycles\n", pois_avg - hash_avg);
    }
    
    // Free stats
    if (atomic_load(&g_timing_poisson_free.total_calls) > 0) {
        uint64_t calls = atomic_load(&g_timing_poisson_free.total_calls);
        uint64_t cycles = atomic_load(&g_timing_poisson_free.total_cycles);
        uint64_t samples = atomic_load(&g_timing_poisson_free.samples_taken);
        uint64_t min_cyc = atomic_load(&g_timing_poisson_free.min_cycles);
        uint64_t max_cyc = atomic_load(&g_timing_poisson_free.max_cycles);
        double avg = (double)cycles / calls;
        double sample_rate = (double)samples / calls * 100.0;
        
        fprintf(stderr, "\nPoisson Sampling (Free):\n");
        fprintf(stderr, "  Total decisions:  %lu\n", calls);
        fprintf(stderr, "  Tracked frees:    %lu (%.2f%%)\n", samples, sample_rate);
        fprintf(stderr, "  Avg cycles:       %.4f\n", avg);
        fprintf(stderr, "  Min cycles:       %lu\n", min_cyc);
        fprintf(stderr, "  Max cycles:       %lu\n", max_cyc);
        fprintf(stderr, "  Total cycles:     %lu\n", cycles);
    }
    
    if (atomic_load(&g_timing_hash_free.total_calls) > 0) {
        uint64_t calls = atomic_load(&g_timing_hash_free.total_calls);
        uint64_t cycles = atomic_load(&g_timing_hash_free.total_cycles);
        uint64_t samples = atomic_load(&g_timing_hash_free.samples_taken);
        uint64_t min_cyc = atomic_load(&g_timing_hash_free.min_cycles);
        uint64_t max_cyc = atomic_load(&g_timing_hash_free.max_cycles);
        double avg = (double)cycles / calls;
        double sample_rate = (double)samples / calls * 100.0;
        
        fprintf(stderr, "\nHash Sampling (Free):\n");
        fprintf(stderr, "  Total decisions:  %lu\n", calls);
        fprintf(stderr, "  Tracked frees:    %lu (%.2f%%)\n", samples, sample_rate);
        fprintf(stderr, "  Avg cycles:       %.4f\n", avg);
        fprintf(stderr, "  Min cycles:       %lu\n", min_cyc);
        fprintf(stderr, "  Max cycles:       %lu\n", max_cyc);
        fprintf(stderr, "  Total cycles:     %lu\n", cycles);
    }
    
    // Free comparison
    if (atomic_load(&g_timing_poisson_free.total_calls) > 0 && 
        atomic_load(&g_timing_hash_free.total_calls) > 0) {
        uint64_t pois_cycles = atomic_load(&g_timing_poisson_free.total_cycles);
        uint64_t hash_cycles = atomic_load(&g_timing_hash_free.total_cycles);
        uint64_t pois_calls = atomic_load(&g_timing_poisson_free.total_calls);
        uint64_t hash_calls = atomic_load(&g_timing_hash_free.total_calls);
        
        double pois_avg = (double)pois_cycles / pois_calls;
        double hash_avg = (double)hash_cycles / hash_calls;
        
        fprintf(stderr, "\nFree Overhead Comparison:\n");
        fprintf(stderr, "  Hash vs Poisson speedup: %.2fx\n", pois_avg / hash_avg);
        fprintf(stderr, "  Absolute difference:     %.4f cycles\n", pois_avg - hash_avg);
    }
    
    fprintf(stderr, "========================================\n\n");
}
