#!/bin/bash
# Generate the stateless sampler C file
cat > sampler_stateless.c << 'EOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <unistd.h>
#include <stdatomic.h>
#include <string.h>
#include <math.h>
#include <pthread.h>
#include <time.h>
#include "sampler_stateless.h"

static StatelessSamplingScheme g_scheme = SCHEME_NONE;
static char *g_stats_file = NULL;
static uint64_t g_hash_mask = DEFAULT_HASH_MASK;
static long g_poisson_mean = DEFAULT_POISSON_MEAN;
static StatelessStats g_stats = {0};

static void *(*real_malloc)(size_t) = NULL;
static void (*real_free)(void *) = NULL;
static void *(*real_calloc)(size_t, size_t) = NULL;
static void *(*real_realloc)(void *, size_t) = NULL;

static atomic_bool g_initialized = false;
static pthread_mutex_t g_init_lock = PTHREAD_MUTEX_INITIALIZER;
static __thread bool t_in_wrapper = false;

typedef struct {
    uint64_t rng_state;
    bool rng_init;
} ThreadRNGState;

static __thread ThreadRNGState tstate = { 
    .rng_state = 0xDEADBEEFCAFEBABE,
    .rng_init = false 
};

// Hash functions
static inline uint64_t hash_xorshift(uint64_t x) {
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    return x * 0x2545F4914F6CDD1DULL;
}

static inline uint64_t hash_splitmix64(uint64_t x) {
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
    x = x ^ (x >> 31);
    return x;
}

static inline uint64_t hash_murmur3_mix(uint64_t x) {
    x ^= x >> 33;
    x *= 0xFF51AFD7ED558CCDULL;
    x ^= x >> 33;
    x *= 0xC4CEB9FE1A85EC53ULL;
    x ^= x >> 33;
    return x;
}

// RNG
static void init_rng() {
    if (!tstate.rng_init) {
        tstate.rng_state = (uint64_t)&tstate ^ (uint64_t)time(NULL) ^ 
                          (uintptr_t)pthread_self() ^ (uint64_t)getpid();
        if (tstate.rng_state == 0) tstate.rng_state = 0xCAFEBABEDEADBEEFULL;
        tstate.rng_init = true;
    }
}

static uint64_t xorshift64(uint64_t *s) {
    uint64_t x = *s;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    *s = x;
    return x * 0x2545F4914F6CDD1DULL;
}

static double rand_uniform() {
    if (!tstate.rng_init) init_rng();
    return (xorshift64(&tstate.rng_state) >> 11) * 0x1.0p-53;
}

// Sampling
static bool should_sample_stateless(void *ptr, size_t size) {
    uintptr_t addr = (uintptr_t)ptr;
    uint64_t h;
    
    switch (g_scheme) {
        case SCHEME_STATELESS_HASH_XOR:
            h = hash_xorshift(addr);
            return (h & g_hash_mask) == 0;
        case SCHEME_STATELESS_HASH_SPLITMIX:
            h = hash_splitmix64(addr);
            return (h & g_hash_mask) == 0;
        case SCHEME_STATELESS_HASH_MURMURISH:
            h = hash_murmur3_mix(addr);
            return (h & g_hash_mask) == 0;
        case SCHEME_STATELESS_POISSON_BERNOULLI: {
            double p = 1.0 - exp(-(double)size / (double)g_poisson_mean);
            double u = rand_uniform();
            return u < p;
        }
        default:
            return false;
    }
}

static int get_size_bin(size_t size) {
    if (size <= 32) return 0;
    if (size <= 64) return 1;
    if (size <= 128) return 2;
    if (size <= 256) return 3;
    if (size <= 512) return 4;
    if (size <= 1024) return 5;
    if (size <= 4096) return 6;
    if (size <= 16384) return 7;
    if (size <= 65536) return 8;
    return 9;
}

static void update_stats_alloc(size_t size, bool sampled) {
    atomic_fetch_add(&g_stats.total_allocs, 1);
    atomic_fetch_add(&g_stats.total_bytes_alloc, size);
    
    int bin = get_size_bin(size);
    atomic_fetch_add(&g_stats.size_bin_total[bin], 1);
    
    if (sampled) {
        atomic_fetch_add(&g_stats.sampled_allocs, 1);
        atomic_fetch_add(&g_stats.sampled_bytes_alloc, size);
        atomic_fetch_add(&g_stats.size_bin_sampled[bin], 1);
        atomic_fetch_add(&g_stats.window_sampled_count, 1);
    }
    
    uint64_t prev_window = atomic_fetch_add(&g_stats.window_alloc_count, 1);
    if ((prev_window + 1) % WINDOW_SIZE == 0) {
        uint64_t samples = atomic_exchange(&g_stats.window_sampled_count, 0);
        atomic_fetch_add(&g_stats.windows_total, 1);
        if (samples == 0) {
            atomic_fetch_add(&g_stats.windows_zero_sampled, 1);
        }
    }
}

static void update_stats_free(void *ptr) {
    atomic_fetch_add(&g_stats.total_frees, 1);
    
    if (g_scheme != SCHEME_STATELESS_POISSON_BERNOULLI) {
        bool was_sampled = should_sample_stateless(ptr, 0);
        if (was_sampled) {
            atomic_fetch_add(&g_stats.sampled_frees_estimate, 1);
        }
    }
}

static void init_sampler() {
    if (atomic_load(&g_initialized)) return;
    
    pthread_mutex_lock(&g_init_lock);
    if (!atomic_load(&g_initialized)) {
        real_malloc = dlsym(RTLD_NEXT, "malloc");
        real_free = dlsym(RTLD_NEXT, "free");
        real_calloc = dlsym(RTLD_NEXT, "calloc");
        real_realloc = dlsym(RTLD_NEXT, "realloc");
        
        if (!real_malloc || !real_free || !real_calloc || !real_realloc) {
            fprintf(stderr, "Error: Could not resolve real allocator functions\n");
            abort();
        }
        
        char *env_scheme = getenv("SAMPLER_SCHEME");
        if (env_scheme) {
            if (strcmp(env_scheme, "STATELESS_HASH_XOR") == 0) {
                g_scheme = SCHEME_STATELESS_HASH_XOR;
            } else if (strcmp(env_scheme, "STATELESS_HASH_SPLITMIX") == 0) {
                g_scheme = SCHEME_STATELESS_HASH_SPLITMIX;
            } else if (strcmp(env_scheme, "STATELESS_HASH_MURMURISH") == 0) {
                g_scheme = SCHEME_STATELESS_HASH_MURMURISH;
            } else if (strcmp(env_scheme, "STATELESS_POISSON_BERNOULLI") == 0) {
                g_scheme = SCHEME_STATELESS_POISSON_BERNOULLI;
            }
        }
        
        g_stats_file = getenv("SAMPLER_STATS_FILE");
        
        char *env_mask = getenv("SAMPLER_HASH_MASK");
        if (env_mask) {
            g_hash_mask = strtoull(env_mask, NULL, 0);
        }
        
        char *env_mean = getenv("SAMPLER_POISSON_MEAN_BYTES");
        if (env_mean) {
            long val = atol(env_mean);
            if (val > 0) g_poisson_mean = val;
        }
        
        atomic_store(&g_initialized, true);
    }
    pthread_mutex_unlock(&g_init_lock);
}

static const char* scheme_name(StatelessSamplingScheme s) {
    switch (s) {
        case SCHEME_STATELESS_HASH_XOR: return "STATELESS_HASH_XOR";
        case SCHEME_STATELESS_HASH_SPLITMIX: return "STATELESS_HASH_SPLITMIX";
        case SCHEME_STATELESS_HASH_MURMURISH: return "STATELESS_HASH_MURMURISH";
        case SCHEME_STATELESS_POISSON_BERNOULLI: return "STATELESS_POISSON_BERNOULLI";
        default: return "NONE";
    }
}

__attribute__((destructor))
static void dump_stats() {
    if (g_scheme == SCHEME_NONE) return;
    
    uint64_t partial_allocs = atomic_load(&g_stats.window_alloc_count) % WINDOW_SIZE;
    if (partial_allocs > 0) {
        atomic_fetch_add(&g_stats.windows_total, 1);
        uint64_t samples = atomic_load(&g_stats.window_sampled_count);
        if (samples == 0) {
            atomic_fetch_add(&g_stats.windows_zero_sampled, 1);
        }
    }
    
    FILE *out = stdout;
    if (g_stats_file) {
        char pid_filename[1024];
        snprintf(pid_filename, sizeof(pid_filename), "%s.%d", g_stats_file, getpid());
        FILE *f = fopen(pid_filename, "w");
        if (f) out = f;
    }
    
    fprintf(out, "{\n");
    fprintf(out, "  \"pid\": %d,\n", getpid());
    fprintf(out, "  \"scheme\": \"%s\",\n", scheme_name(g_scheme));
    fprintf(out, "  \"scheme_id\": %d,\n", g_scheme);
    fprintf(out, "  \"stateless\": true,\n");
    fprintf(out, "  \"hash_mask\": \"0x%lx\",\n", g_hash_mask);
    fprintf(out, "  \"poisson_mean_bytes\": %ld,\n", g_poisson_mean);
    fprintf(out, "  \"window_size\": %d,\n", WINDOW_SIZE);
    fprintf(out, "  \"total_allocs\": %lu,\n", g_stats.total_allocs);
    fprintf(out, "  \"total_frees\": %lu,\n", g_stats.total_frees);
    fprintf(out, "  \"total_bytes_alloc\": %lu,\n", g_stats.total_bytes_alloc);
    fprintf(out, "  \"sampled_allocs\": %lu,\n", g_stats.sampled_allocs);
    fprintf(out, "  \"sampled_frees_estimate\": %lu,\n", g_stats.sampled_frees_estimate);
    fprintf(out, "  \"sampled_bytes_alloc\": %lu,\n", g_stats.sampled_bytes_alloc);
    
    double rate_allocs = g_stats.total_allocs > 0 ? 
        (double)g_stats.sampled_allocs / g_stats.total_allocs : 0.0;
    double rate_bytes = g_stats.total_bytes_alloc > 0 ? 
        (double)g_stats.sampled_bytes_alloc / g_stats.total_bytes_alloc : 0.0;
    
    fprintf(out, "  \"sample_rate_allocs\": %.6f,\n", rate_allocs);
    fprintf(out, "  \"sample_rate_bytes\": %.6f,\n", rate_bytes);
    
    long live_estimate = (long)g_stats.sampled_allocs - (long)g_stats.sampled_frees_estimate;
    if (live_estimate < 0) live_estimate = 0;
    fprintf(out, "  \"sampled_live_allocs_estimate\": %ld,\n", live_estimate);
    
    fprintf(out, "  \"windows_total\": %lu,\n", g_stats.windows_total);
    fprintf(out, "  \"windows_zero_sampled\": %lu,\n", g_stats.windows_zero_sampled);
    
    uint64_t window_remainder = atomic_load(&g_stats.window_alloc_count) % WINDOW_SIZE;
    fprintf(out, "  \"window_remainder_allocs\": %lu,\n", window_remainder);
    
    fprintf(out, "  \"size_bins\": {\n");
    const char *bins[] = {"0-32", "33-64", "65-128", "129-256", "257-512", 
                          "513-1024", "1025-4096", "4097-16384", "16385-65536", ">65536"};
    for (int i = 0; i < NUM_SIZE_BINS; i++) {
        fprintf(out, "    \"%s\": { \"total\": %lu, \"sampled\": %lu }", 
            bins[i], g_stats.size_bin_total[i], g_stats.size_bin_sampled[i]);
        if (i < NUM_SIZE_BINS - 1) fprintf(out, ",\n");
    }
    fprintf(out, "\n  }\n");
    fprintf(out, "}\n");
    
    if (g_stats_file && out != stdout) fclose(out);
}

void *malloc(size_t size) {
    if (t_in_wrapper) return NULL;
    if (!atomic_load(&g_initialized)) init_sampler();
    
    t_in_wrapper = true;
    void *ptr = real_malloc(size);
    
    if (ptr && g_scheme != SCHEME_NONE) {
        bool is_sampled = should_sample_stateless(ptr, size);
        update_stats_alloc(size, is_sampled);
    }
    
    t_in_wrapper = false;
    return ptr;
}

void free(void *ptr) {
    if (!ptr) return;
    if (t_in_wrapper) return;
    if (!atomic_load(&g_initialized)) init_sampler();
    
    t_in_wrapper = true;
    
    if (g_scheme != SCHEME_NONE) {
        update_stats_free(ptr);
    }
    
    real_free(ptr);
    t_in_wrapper = false;
}

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
    void *ptr = real_calloc(nmemb, size);
    
    if (ptr && g_scheme != SCHEME_NONE) {
        size_t total_size = nmemb * size;
        bool is_sampled = should_sample_stateless(ptr, total_size);
        update_stats_alloc(total_size, is_sampled);
    }
    
    t_in_wrapper = false;
    return ptr;
}

void *realloc(void *ptr, size_t size) {
    if (!atomic_load(&g_initialized)) init_sampler();
    
    if (!ptr) return malloc(size);
    if (size == 0) {
        free(ptr);
        return NULL;
    }
    
    t_in_wrapper = true;
    
    if (g_scheme != SCHEME_NONE) {
        update_stats_free(ptr);
    }
    
    void *new_ptr = real_realloc(ptr, size);
    
    if (new_ptr && g_scheme != SCHEME_NONE) {
        bool is_sampled = should_sample_stateless(new_ptr, size);
        update_stats_alloc(size, is_sampled);
    }
    
    t_in_wrapper = false;
    return new_ptr;
}
EOF
