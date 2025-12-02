#!/bin/bash
# Generate the all-headers sampler C file
cat > sampler_all_headers.c << 'EOF'
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
#include "sampler_all_headers.h"

static AllHeadersSamplingScheme g_scheme = SCHEME_NONE;
static char *g_stats_file = NULL;
static uint64_t g_hash_mask = DEFAULT_HASH_MASK;
static long g_poisson_mean = DEFAULT_POISSON_MEAN;
static AllHeadersStats g_stats = {0};

#define PAGE_BITMAP_SIZE 4096
static atomic_uint_least64_t g_page_seen_bits[PAGE_BITMAP_SIZE / 64];
static atomic_uint_least64_t g_page_sampled_bits[PAGE_BITMAP_SIZE / 64];

static void *(*real_malloc)(size_t) = NULL;
static void (*real_free)(void *) = NULL;
static void *(*real_calloc)(size_t, size_t) = NULL;
static void *(*real_realloc)(void *, size_t) = NULL;

static atomic_bool g_initialized = false;
static pthread_mutex_t g_init_lock = PTHREAD_MUTEX_INITIALIZER;
static __thread bool t_in_wrapper = false;

typedef struct {
    long bytes_until_next;
    uint64_t rng_state;
    bool rng_init;
} ThreadSamplerState;

static __thread ThreadSamplerState tstate = { 
    .bytes_until_next = -1,
    .rng_state = 0xDEADBEEFCAFEBABE,
    .rng_init = false 
};

static inline uint64_t hash64(uint64_t x) {
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    return x * 0x2545F4914F6CDD1DULL;
}

static void init_rng() {
    if (!tstate.rng_init) {
        tstate.rng_state = (uint64_t)&tstate ^ (uint64_t)time(NULL) ^ 
                          (uintptr_t)pthread_self();
        if (tstate.rng_state == 0) tstate.rng_state = 0xCAFEBABE;
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

static long draw_geometric_bytes(long mean_bytes) {
    if (!tstate.rng_init) init_rng();
    double u = (xorshift64(&tstate.rng_state) >> 11) * 0x1.0p-53;
    if (u <= 0.0) u = 1e-12;
    return (long)(-log(u) * mean_bytes);
}

static bool should_sample_alloc_poisson(size_t size) {
    if (tstate.bytes_until_next < 0) {
        tstate.bytes_until_next = draw_geometric_bytes(g_poisson_mean);
    }
    tstate.bytes_until_next -= (long)size;
    if (tstate.bytes_until_next <= 0) {
        tstate.bytes_until_next = draw_geometric_bytes(g_poisson_mean);
        return true;
    }
    return false;
}

static bool should_sample_alloc_page_hash(void *real_ptr, size_t size) {
    (void)size;
    uintptr_t addr = (uintptr_t)real_ptr;
    uintptr_t page = addr >> 12;
    uint64_t h = hash64(page);
    return (h & g_hash_mask) == 0;
}

static bool should_sample(void *ptr, size_t size) {
    switch (g_scheme) {
        case SCHEME_HEADER_HASH: {
            uintptr_t h = (uintptr_t)ptr;
            h ^= h >> 12;
            h ^= h << 25;
            h ^= h >> 27;
            return (h & g_hash_mask) == 0;
        }
        case SCHEME_HEADER_PAGE_HASH: {
            return should_sample_alloc_page_hash(ptr, size);
        }
        case SCHEME_HEADER_POISSON_BYTES: {
            return should_sample_alloc_poisson(size);
        }
        case SCHEME_HEADER_HYBRID: {
            if (size < HYBRID_SMALL_THRESH) {
                return should_sample_alloc_poisson(size);
            } else {
                uintptr_t h = (uintptr_t)ptr;
                h ^= h >> 12;
                h ^= h << 25;
                h ^= h >> 27;
                return (h & g_hash_mask) == 0;
            }
        }
        default:
            return false;
    }
}

static void track_page_approx(void *ptr, bool is_sampled) {
    if (g_scheme != SCHEME_HEADER_PAGE_HASH) return;
    
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

static void update_stats_free(size_t size, bool sampled) {
    atomic_fetch_add(&g_stats.total_frees, 1);
    if (sampled) {
        atomic_fetch_add(&g_stats.sampled_frees, 1);
        atomic_fetch_add(&g_stats.sampled_bytes_freed, size);
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
            if (strcmp(env_scheme, "HEADER_HASH") == 0) {
                g_scheme = SCHEME_HEADER_HASH;
            } else if (strcmp(env_scheme, "HEADER_PAGE_HASH") == 0) {
                g_scheme = SCHEME_HEADER_PAGE_HASH;
            } else if (strcmp(env_scheme, "HEADER_POISSON_BYTES") == 0) {
                g_scheme = SCHEME_HEADER_POISSON_BYTES;
            } else if (strcmp(env_scheme, "HEADER_HYBRID") == 0) {
                g_scheme = SCHEME_HEADER_HYBRID;
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

static const char* scheme_name(AllHeadersSamplingScheme s) {
    switch (s) {
        case SCHEME_HEADER_HASH: return "HEADER_HASH";
        case SCHEME_HEADER_PAGE_HASH: return "HEADER_PAGE_HASH";
        case SCHEME_HEADER_POISSON_BYTES: return "HEADER_POISSON_BYTES";
        case SCHEME_HEADER_HYBRID: return "HEADER_HYBRID";
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
    fprintf(out, "  \"all_headers\": true,\n");
    fprintf(out, "  \"header_size\": %d,\n", HEADER_SIZE);
    fprintf(out, "  \"hash_mask\": \"0x%lx\",\n", g_hash_mask);
    fprintf(out, "  \"poisson_mean_bytes\": %ld,\n", g_poisson_mean);
    fprintf(out, "  \"hybrid_threshold\": %d,\n", HYBRID_SMALL_THRESH);
    fprintf(out, "  \"window_size\": %d,\n", WINDOW_SIZE);
    fprintf(out, "  \"total_allocs\": %lu,\n", g_stats.total_allocs);
    fprintf(out, "  \"total_frees\": %lu,\n", g_stats.total_frees);
    fprintf(out, "  \"total_bytes_alloc\": %lu,\n", g_stats.total_bytes_alloc);
    fprintf(out, "  \"sampled_allocs\": %lu,\n", g_stats.sampled_allocs);
    fprintf(out, "  \"sampled_frees\": %lu,\n", g_stats.sampled_frees);
    fprintf(out, "  \"sampled_bytes_alloc\": %lu,\n", g_stats.sampled_bytes_alloc);
    fprintf(out, "  \"sampled_bytes_freed\": %lu,\n", g_stats.sampled_bytes_freed);
    
    double rate_allocs = g_stats.total_allocs > 0 ? 
        (double)g_stats.sampled_allocs / g_stats.total_allocs : 0.0;
    double rate_bytes = g_stats.total_bytes_alloc > 0 ? 
        (double)g_stats.sampled_bytes_alloc / g_stats.total_bytes_alloc : 0.0;
    
    fprintf(out, "  \"sample_rate_allocs\": %.6f,\n", rate_allocs);
    fprintf(out, "  \"sample_rate_bytes\": %.6f,\n", rate_bytes);
    
    long live_estimate = (long)g_stats.sampled_allocs - (long)g_stats.sampled_frees;
    if (live_estimate < 0) live_estimate = 0;
    fprintf(out, "  \"sampled_live_allocs_estimate\": %ld,\n", live_estimate);
    
    fprintf(out, "  \"windows_total\": %lu,\n", g_stats.windows_total);
    fprintf(out, "  \"windows_zero_sampled\": %lu,\n", g_stats.windows_zero_sampled);
    
    uint64_t window_remainder = atomic_load(&g_stats.window_alloc_count) % WINDOW_SIZE;
    fprintf(out, "  \"window_remainder_allocs\": %lu,\n", window_remainder);
    
    if (g_scheme == SCHEME_HEADER_PAGE_HASH) {
        fprintf(out, "  \"approx_unique_pages\": %lu,\n", g_stats.approx_unique_pages);
        fprintf(out, "  \"approx_sampled_pages\": %lu,\n", g_stats.approx_sampled_pages);
    }
    
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
    
    size_t total_size = size + HEADER_SIZE;
    void *ptr = real_malloc(total_size);
    
    if (!ptr) {
        t_in_wrapper = false;
        return NULL;
    }
    
    SampleHeader *header = (SampleHeader *)ptr;
    void *user_ptr = (char *)ptr + HEADER_SIZE;
    
    header->magic = SAMPLE_MAGIC;
    
    bool is_sampled = should_sample(ptr, size);
    header->flags = is_sampled ? FLAG_SAMPLED : 0;
    header->reserved = (uint32_t)size;
    
    if (g_scheme == SCHEME_HEADER_PAGE_HASH) {
        track_page_approx(ptr, is_sampled);
    }
    
    update_stats_alloc(size, is_sampled);
    
    t_in_wrapper = false;
    return user_ptr;
}

void free(void *ptr) {
    if (!ptr) return;
    if (t_in_wrapper) return;
    if (!atomic_load(&g_initialized)) init_sampler();
    
    t_in_wrapper = true;
    
    SampleHeader *header = (SampleHeader *)((char *)ptr - HEADER_SIZE);
    
    if (header->magic == SAMPLE_MAGIC) {
        bool is_sampled = (header->flags & FLAG_SAMPLED);
        size_t size = header->reserved;
        
        update_stats_free(size, is_sampled);
        
        header->magic = 0;
        real_free(header);
    } else {
        real_free(ptr);
    }
    
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
    
    if (g_scheme == SCHEME_HEADER_PAGE_HASH) {
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
    
    if (g_scheme == SCHEME_HEADER_PAGE_HASH) {
        track_page_approx(new_base, is_sampled);
    }
    
    update_stats_alloc(size, is_sampled);
    
    t_in_wrapper = false;
    return new_user_ptr;
}
EOF
