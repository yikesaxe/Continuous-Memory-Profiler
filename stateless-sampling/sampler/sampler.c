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
static long g_poisson_mean = DEFAULT_POISSON_MEAN; // Tunable via env var
static Stats g_stats = {0};
static bool g_combined_mode = false; // Run both Poisson and Hash simultaneously

// Page tracking bitmaps for PAGE_HASH approximation
#define PAGE_BITMAP_SIZE 4096
static atomic_uint_least64_t g_page_seen_bits[PAGE_BITMAP_SIZE / 64];
static atomic_uint_least64_t g_page_sampled_bits[PAGE_BITMAP_SIZE / 64];

// Function pointers to real allocators
static void *(*real_malloc)(size_t) = NULL;
static void (*real_free)(void *) = NULL;
//static void *(*real_calloc)(size_t, size_t) = NULL;
//static void *(*real_realloc)(void *, size_t) = NULL;

// Initialization state
static atomic_bool g_initialized = false;
static pthread_mutex_t g_init_lock = PTHREAD_MUTEX_INITIALIZER;

// Thread-local recursion guard
static __thread bool t_in_wrapper = false;

// Hash sets to track sampled addresses
#define SAMPLED_SET_SIZE 1048576  // 1M entries
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
            g_sampled_addrs_poisson[probe] = NULL; // Remove it
            break;
        }
        if (g_sampled_addrs_poisson[probe] == NULL) break;
    }
    pthread_mutex_unlock(&g_sampled_lock_poisson);
    return found;
}

static bool was_sampled_hash(void *ptr) {
    // Stateless: just re-hash the address
    uintptr_t h = (uintptr_t)ptr;
    h ^= h >> 12;
    h ^= h << 25;
    h ^= h >> 27;
    return (h & DEFAULT_HASH_MASK) == 0;
}

// Thread-local Sampler State
typedef struct {
    // Poisson state
    int64_t pois_bytes_until_next;
    bool pois_bytes_inited;
    
    // Stateless Hash state
    int64_t hash_running_bytes;
    
    // RNG for Poisson
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

// Xorshift64* RNG
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
        // Simple seed based on address of a local variable + time
        tstate.rng_state = (uint64_t)&tstate ^ (uint64_t)time(NULL) ^ (uintptr_t)pthread_self();
        if (tstate.rng_state == 0) tstate.rng_state = 0xCAFEBABE;
        tstate.rng_init = true;
    }
}

// Geometric distribution for Poisson sampling
// Returns the number of bytes to skip until the next sample
static long draw_geometric_bytes(long mean_bytes) {
    if (!tstate.rng_init) init_rng();
    
    // Generate uniform double in (0, 1]
    double u = (xorshift64(&tstate.rng_state) >> 11) * 0x1.0p-53;
    if (u <= 0.0) u = 1e-12; // Avoid log(0)
    
    // Geometric distribution via inverse transform: -log(u) * mean
    return (long)(-log(u) * mean_bytes);
}

// Initialize real function pointers and configuration
static void init_sampler() {
    if (atomic_load(&g_initialized)) return;

    pthread_mutex_lock(&g_init_lock);
    if (!atomic_load(&g_initialized)) {
        real_malloc = dlsym(RTLD_NEXT, "malloc");
        real_free = dlsym(RTLD_NEXT, "free");
        //real_calloc = dlsym(RTLD_NEXT, "calloc");
        //real_realloc = dlsym(RTLD_NEXT, "realloc");

        if (!real_malloc || !real_free /*|| !real_calloc || !real_realloc*/) {
            fprintf(stderr, "Error: Could not resolve real allocator functions: %s\n", dlerror());
            abort();
        }

        // Parse Env Vars
        char *env_scheme = getenv("SAMPLER_SCHEME");
        if (env_scheme) {
            if (strcmp(env_scheme, "COMBINED") == 0) {
                g_combined_mode = true;
                g_scheme = SCHEME_NONE; // Run as ground truth
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

// Stateless page-based sampling:
// - Hashes the page number (addr >> 12) instead of the full address.
// - Samples all allocations landing on "sampled pages".
// - This reduces the risk that a tiny hot set of addresses all land in an unsampled region,
//   at the cost of sampling entire pages.
static bool should_sample_alloc_page_hash(void *real_ptr, size_t size) {
    (void)size; // unused
    uintptr_t addr = (uintptr_t)real_ptr;
    // Assume 4KB pages
    uintptr_t page = addr >> 12;
    uint64_t h = hash64(page);
    return (h & DEFAULT_HASH_MASK) == 0;
}

// Evaluate Poisson sampling decision
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

// Evaluate Stateless Hash sampling decision
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

// Returns: reported_size (0 if not sampled)
// For STATELESS_HASH, this is accumulated bytes (weight)
// Actual size is still available in the calling context
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

/*
// Update approximate page tracking
static void track_page_approx(void *ptr, bool is_sampled) {
    if (g_scheme != SCHEME_PAGE_HASH) return;

    uintptr_t addr = (uintptr_t)ptr;
    uintptr_t page = addr >> 12;
    size_t idx = (page & (PAGE_BITMAP_SIZE - 1)) >> 6;
    uint64_t bit = 1ULL << (page & 63);

    uint64_t old_seen = atomic_fetch_or(&g_page_seen_bits[idx], bit);
    if ((old_seen & bit) == 0) {
        atomic_fetch_add(&g_stats.approx_unique_pages, 1);
    }

    if (is_sampled) {
        uint64_t old_samp = atomic_fetch_or(&g_page_sampled_bits[idx], bit);
        if ((old_samp & bit) == 0) {
            atomic_fetch_add(&g_stats.approx_sampled_pages, 1);
        }
    }
}
*/
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
        // Update counters for both schemes
        tstate.pois_bytes_until_next += size;
        tstate.hash_running_bytes += size;
        
        // Evaluate Poisson sampling
        size_t pois_size = sample_poisson(size);
        bool pois_tracked = (pois_size > 0);
        if (pois_tracked) {
            mark_sampled_poisson(ptr);
        }
        
        // Evaluate Hash sampling
        size_t hash_size = sample_hash(ptr);
        bool hash_tracked = (hash_size > 0);
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
        tstate.hash_running_bytes += size; // for stateless hash
        tstate.pois_bytes_until_next += size; // for poisson
        size_t reported_size = sample(ptr, size);
        if (reported_size) {
            // Mark this address as sampled
            if (g_scheme == SCHEME_POISSON) {
                mark_sampled_poisson(ptr);
            } else if (g_scheme == SCHEME_STATELESS_HASH) {
                mark_sampled_hash(ptr);
            }
            
            // Log format: MALLOC, timestamp, address, actual_size, weight
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
        // COMBINED MODE: Check both schemes
        bool pois_tracked = was_sampled_poisson(ptr);
        bool hash_tracked = was_sampled_hash(ptr);
        
        // Log format: FREE, timestamp, address, -1, poisson_tracked, -1, hash_tracked, -1
        printf("FREE, %ld.%09ld, %p, -1, %d, -1, %d, -1\n",
            ts.tv_sec, ts.tv_nsec,
            ptr,
            pois_tracked ? 1 : 0,
            hash_tracked ? 1 : 0
        );

    } else {
        // LEGACY MODE: Single scheme
        bool should_log = false;
        if (g_scheme == SCHEME_NONE) {
            should_log = true;
        } else if (g_scheme == SCHEME_POISSON) {
            should_log = was_sampled_poisson(ptr);
        } else if (g_scheme == SCHEME_STATELESS_HASH) {
            should_log = was_sampled_hash(ptr);
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

/*
void *calloc(size_t nmemb, size_t size) {
    if (t_in_wrapper) {
        static char static_buf[4096];
        static size_t used = 0;
        size_t req = nmemb * size;
        if (used + req < sizeof(static_buf)) {
            void *ret = static_buf + used;
            used += req;
            return ret;
        }
        return NULL;
    }

    if (!atomic_load(&g_initialized)) init_sampler();

    t_in_wrapper = true;

    size_t user_size = nmemb * size;
    size_t total_size = user_size + HEADER_SIZE;

    void *ptr = real_calloc(1, total_size);

    if (!ptr) {
        t_in_wrapper = false;
        return NULL;
    }

    SampleHeader *header = (SampleHeader *)ptr;
    void *user_ptr = (char *)ptr + HEADER_SIZE;

    header->magic = SAMPLE_MAGIC;
    bool is_sampled = should_sample(ptr, user_size);
    header->flags = is_sampled ? FLAG_SAMPLED : 0;
    header->reserved = (uint32_t)user_size;

    if (g_scheme == SCHEME_PAGE_HASH) {
        track_page_approx(ptr, is_sampled);
    }

    update_stats_alloc(user_size, is_sampled);

    t_in_wrapper = false;
    return user_ptr;
}

void *realloc(void *ptr, size_t size) {
    if (!atomic_load(&g_initialized)) init_sampler();

    if (!ptr) return malloc(size);
    if (size == 0) {
        free(ptr);
        return NULL;
    }

    t_in_wrapper = true;

    SampleHeader *old_header = (SampleHeader *)((char *)ptr - HEADER_SIZE);
    
    if (old_header->magic != SAMPLE_MAGIC) {
        t_in_wrapper = false;
        
        size_t old_len = malloc_usable_size(ptr);
        void *new_ptr = malloc(size);
        if (!new_ptr) return NULL;
        
        size_t copy_len = (old_len < size) ? old_len : size;
        memcpy(new_ptr, ptr, copy_len);
        real_free(ptr);
        
        return new_ptr;
    }

    bool was_sampled = (old_header->flags & FLAG_SAMPLED);
    size_t old_size = old_header->reserved;

    size_t total_size = size + HEADER_SIZE;
    void *new_base = real_realloc(old_header, total_size);

    if (!new_base) {
        t_in_wrapper = false;
        return NULL;
    }

    SampleHeader *new_header = (SampleHeader *)new_base;
    void *new_user_ptr = (char *)new_base + HEADER_SIZE;

    update_stats_free(old_size, was_sampled);

    new_header->magic = SAMPLE_MAGIC;
    new_header->reserved = (uint32_t)size;
    
    bool is_sampled = should_sample(new_base, size);
    new_header->flags = is_sampled ? FLAG_SAMPLED : 0;

    if (g_scheme == SCHEME_PAGE_HASH) {
        track_page_approx(new_base, is_sampled);
    }

    update_stats_alloc(size, is_sampled);

    t_in_wrapper = false;
    return new_user_ptr;
}

*/