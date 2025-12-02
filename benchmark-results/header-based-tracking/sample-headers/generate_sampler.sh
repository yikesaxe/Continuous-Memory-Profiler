#!/bin/bash
cat > sampler_sample_headers.c << 'EOF'
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
#include <malloc.h>
#include "sampler_sample_headers.h"

static SampleHeadersScheme g_scheme = SCHEME_NONE;
static char *g_stats_file = NULL;
static uint64_t g_hash_mask = DEFAULT_HASH_MASK;
static long g_poisson_mean = DEFAULT_POISSON_MEAN;
static SampleHeadersStats g_stats = {0};

// Hash table for tracking sampled allocations
static HashEntry *g_hash_table[HASH_TABLE_SIZE];
static pthread_mutex_t g_hash_lock = PTHREAD_MUTEX_INITIALIZER;

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

// Hash function for hash table
static inline uint32_t hash_ptr(void *ptr) {
    uintptr_t h = (uintptr_t)ptr;
    h ^= h >> 12;
    h ^= h << 25;
    h ^= h >> 27;
    return (uint32_t)(h * 0x2545F4914F6CDD1DULL);
}

static inline uint64_t hash64(uint64_t x) {
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    return x * 0x2545F4914F6CDD1DULL;
}

static void init_rng() {
    if (!tstate.rng_init) {
        tstate.rng_state = (uint64_t)&tstate ^ (uint64_t)time(NULL) ^ (uintptr_t)pthread_self();
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

static double rand_uniform() {
    if (!tstate.rng_init) init_rng();
    return (xorshift64(&tstate.rng_state) >> 11) * 0x1.0p-53;
}

// Hash table operations
static void hash_table_insert(void *user_ptr, void *header_ptr) {
    uint32_t idx = hash_ptr(user_ptr) & HASH_TABLE_MASK;
    
    HashEntry *entry = (HashEntry *)real_malloc(sizeof(HashEntry));
    if (!entry) return;
    
    entry->key = user_ptr;
    entry->header_ptr = header_ptr;
    
    pthread_mutex_lock(&g_hash_lock);
    entry->next = g_hash_table[idx];
    g_hash_table[idx] = entry;
    
    atomic_fetch_add(&g_stats.map_inserts, 1);
    atomic_fetch_add(&g_stats.map_current_size, 1);
    
    uint64_t current = atomic_load(&g_stats.map_current_size);
    uint64_t peak = atomic_load(&g_stats.map_peak_size);
    if (current > peak) {
        atomic_store(&g_stats.map_peak_size, current);
    }
    
    pthread_mutex_unlock(&g_hash_lock);
}

static void* hash_table_lookup(void *user_ptr) {
    uint32_t idx = hash_ptr(user_ptr) & HASH_TABLE_MASK;
    
    atomic_fetch_add(&g_stats.map_lookups, 1);
    
    pthread_mutex_lock(&g_hash_lock);
    HashEntry *entry = g_hash_table[idx];
    while (entry) {
        if (entry->key == user_ptr) {
            void *header_ptr = entry->header_ptr;
            pthread_mutex_unlock(&g_hash_lock);
            return header_ptr;
        }
        entry = entry->next;
    }
    pthread_mutex_unlock(&g_hash_lock);
    return NULL;
}

static bool hash_table_remove(void *user_ptr) {
    uint32_t idx = hash_ptr(user_ptr) & HASH_TABLE_MASK;
    
    pthread_mutex_lock(&g_hash_lock);
    HashEntry **prev = &g_hash_table[idx];
    HashEntry *entry = g_hash_table[idx];
    
    while (entry) {
        if (entry->key == user_ptr) {
            *prev = entry->next;
            real_free(entry);
            
            atomic_fetch_add(&g_stats.map_deletes, 1);
            atomic_fetch_sub(&g_stats.map_current_size, 1);
            
            pthread_mutex_unlock(&g_hash_lock);
            return true;
        }
        prev = &entry->next;
        entry = entry->next;
    }
    
    pthread_mutex_unlock(&g_hash_lock);
    return false;
}

// Sampling decision functions
static bool should_sample_poisson(size_t size) {
    double p = 1.0 - exp(-(double)size / (double)g_poisson_mean);
    double u = rand_uniform();
    return u < p;
}

static bool should_sample_hash(void *ptr) {
    uint64_t h = hash64((uintptr_t)ptr);
    return (h & g_hash_mask) == 0;
}

static bool should_sample_ebpf_inspired(size_t size) {
    // eBPF-inspired: use Poisson as pre-filter
    // In real eBPF: this would be kernel-side decision
    // Promoted samples get tracked in map (like eBPF map)
    return should_sample_poisson(size);
}

static bool decide_to_sample(void *ptr, size_t size) {
    switch (g_scheme) {
        case SCHEME_SAMPLE_HEADERS_POISSON_MAP:
            return should_sample_poisson(size);
        case SCHEME_SAMPLE_HEADERS_HASH_MAP:
            return should_sample_hash(ptr);
        case SCHEME_SAMPLE_HEADERS_EBPF_INSPIRED:
            return should_sample_ebpf_inspired(size);
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
        
        // Initialize hash table
        memset(g_hash_table, 0, sizeof(g_hash_table));
        
        char *env_scheme = getenv("SAMPLER_SCHEME");
        if (env_scheme) {
            if (strcmp(env_scheme, "SAMPLE_HEADERS_POISSON_MAP") == 0) {
                g_scheme = SCHEME_SAMPLE_HEADERS_POISSON_MAP;
            } else if (strcmp(env_scheme, "SAMPLE_HEADERS_HASH_MAP") == 0) {
                g_scheme = SCHEME_SAMPLE_HEADERS_HASH_MAP;
            } else if (strcmp(env_scheme, "SAMPLE_HEADERS_EBPF_INSPIRED") == 0) {
                g_scheme = SCHEME_SAMPLE_HEADERS_EBPF_INSPIRED;
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

static const char* scheme_name(SampleHeadersScheme s) {
    switch (s) {
        case SCHEME_SAMPLE_HEADERS_POISSON_MAP: return "SAMPLE_HEADERS_POISSON_MAP";
        case SCHEME_SAMPLE_HEADERS_HASH_MAP: return "SAMPLE_HEADERS_HASH_MAP";
        case SCHEME_SAMPLE_HEADERS_EBPF_INSPIRED: return "SAMPLE_HEADERS_EBPF_INSPIRED";
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
    fprintf(out, "  \"sample_headers\": true,\n");
    fprintf(out, "  \"header_size\": %d,\n", HEADER_SIZE);
    fprintf(out, "  \"hash_mask\": \"0x%lx\",\n", g_hash_mask);
    fprintf(out, "  \"poisson_mean_bytes\": %ld,\n", g_poisson_mean);
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
    
    // Map metrics
    fprintf(out, "  \"map_inserts\": %lu,\n", g_stats.map_inserts);
    fprintf(out, "  \"map_lookups\": %lu,\n", g_stats.map_lookups);
    fprintf(out, "  \"map_deletes\": %lu,\n", g_stats.map_deletes);
    fprintf(out, "  \"map_current_size\": %lu,\n", g_stats.map_current_size);
    fprintf(out, "  \"map_peak_size\": %lu,\n", g_stats.map_peak_size);
    
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
    
    // DECISION BEFORE ALLOCATION
    // For hash-based, we need a temporary allocation to get the address
    void *temp_ptr = NULL;
    bool is_sampled = false;
    
    if (g_scheme == SCHEME_SAMPLE_HEADERS_HASH_MAP) {
        // Need address first for hash-based decision
        temp_ptr = real_malloc(size);
        if (!temp_ptr) {
            t_in_wrapper = false;
            return NULL;
        }
        is_sampled = decide_to_sample(temp_ptr, size);
    } else {
        // Poisson/eBPF can decide without address
        is_sampled = decide_to_sample(NULL, size);
    }
    
    void *result;
    
    if (is_sampled) {
        // Sampled: allocate with header
        if (temp_ptr) real_free(temp_ptr);  // Free temp if we had one
        
        size_t total_size = size + HEADER_SIZE;
        void *header_ptr = real_malloc(total_size);
        
        if (!header_ptr) {
            t_in_wrapper = false;
            return NULL;
        }
        
        SampleHeader *header = (SampleHeader *)header_ptr;
        void *user_ptr = (char *)header_ptr + HEADER_SIZE;
        
        header->magic = SAMPLE_MAGIC;
        header->flags = FLAG_SAMPLED;
        header->reserved = (uint32_t)size;
        
        // Insert into map
        hash_table_insert(user_ptr, header_ptr);
        
        result = user_ptr;
    } else {
        // Not sampled: plain allocation
        if (temp_ptr) {
            result = temp_ptr;  // Reuse temp
        } else {
            result = real_malloc(size);
        }
    }
    
    update_stats_alloc(size, is_sampled);
    
    t_in_wrapper = false;
    return result;
}

void free(void *ptr) {
    if (!ptr) return;
    if (t_in_wrapper) return;
    if (!atomic_load(&g_initialized)) init_sampler();
    
    t_in_wrapper = true;
    
    // Check if this pointer is in our map
    void *header_ptr = hash_table_lookup(ptr);
    
    if (header_ptr) {
        // It's sampled! Has a header
        SampleHeader *header = (SampleHeader *)header_ptr;
        
        if (header->magic == SAMPLE_MAGIC) {
            size_t size = header->reserved;
            update_stats_free(size, true);
            
            // Remove from map
            hash_table_remove(ptr);
            
            // Free header block
            real_free(header_ptr);
        } else {
            // Corrupted? Just free
            real_free(ptr);
        }
    } else {
        // Not sampled: plain free
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
    bool is_sampled = decide_to_sample(NULL, user_size);
    
    void *result;
    
    if (is_sampled) {
        size_t total_size = user_size + HEADER_SIZE;
        void *header_ptr = real_calloc(1, total_size);
        
        if (!header_ptr) {
            t_in_wrapper = false;
            return NULL;
        }
        
        SampleHeader *header = (SampleHeader *)header_ptr;
        void *user_ptr = (char *)header_ptr + HEADER_SIZE;
        
        header->magic = SAMPLE_MAGIC;
        header->flags = FLAG_SAMPLED;
        header->reserved = (uint32_t)user_size;
        
        hash_table_insert(user_ptr, header_ptr);
        result = user_ptr;
    } else {
        result = real_calloc(nmemb, size);
    }
    
    update_stats_alloc(user_size, is_sampled);
    
    t_in_wrapper = false;
    return result;
}

void *realloc(void *ptr, size_t size) {
    if (!atomic_load(&g_initialized)) init_sampler();
    
    if (!ptr) return malloc(size);
    if (size == 0) {
        free(ptr);
        return NULL;
    }
    
    t_in_wrapper = true;
    
    // Check if old pointer was sampled
    void *old_header_ptr = hash_table_lookup(ptr);
    
    size_t old_size = 0;
    bool was_sampled = (old_header_ptr != NULL);
    
    if (was_sampled) {
        SampleHeader *old_header = (SampleHeader *)old_header_ptr;
        old_size = old_header->reserved;
        update_stats_free(old_size, true);
        hash_table_remove(ptr);
    }
    
    // Decide for new allocation
    bool is_sampled = decide_to_sample(NULL, size);
    
    void *result;
    
    if (was_sampled && is_sampled) {
        // Both have headers: realloc header block
        size_t total_size = size + HEADER_SIZE;
        void *new_header_ptr = real_realloc(old_header_ptr, total_size);
        
        if (!new_header_ptr) {
            t_in_wrapper = false;
            return NULL;
        }
        
        SampleHeader *new_header = (SampleHeader *)new_header_ptr;
        void *new_user_ptr = (char *)new_header_ptr + HEADER_SIZE;
        
        new_header->magic = SAMPLE_MAGIC;
        new_header->flags = FLAG_SAMPLED;
        new_header->reserved = (uint32_t)size;
        
        hash_table_insert(new_user_ptr, new_header_ptr);
        result = new_user_ptr;
        
    } else if (was_sampled && !is_sampled) {
        // Had header, new doesn't: copy and remove header
        void *new_ptr = real_malloc(size);
        if (new_ptr) {
            size_t copy_size = (old_size < size) ? old_size : size;
            memcpy(new_ptr, ptr, copy_size);
        }
        real_free(old_header_ptr);
        result = new_ptr;
        
    } else if (!was_sampled && is_sampled) {
        // Didn't have header, new does: add header
        size_t total_size = size + HEADER_SIZE;
        void *new_header_ptr = real_malloc(total_size);
        
        if (new_header_ptr) {
            SampleHeader *header = (SampleHeader *)new_header_ptr;
            void *new_user_ptr = (char *)new_header_ptr + HEADER_SIZE;
            
            size_t old_len = malloc_usable_size(ptr);
            size_t copy_size = (old_len < size) ? old_len : size;
            memcpy(new_user_ptr, ptr, copy_size);
            
            header->magic = SAMPLE_MAGIC;
            header->flags = FLAG_SAMPLED;
            header->reserved = (uint32_t)size;
            
            hash_table_insert(new_user_ptr, new_header_ptr);
            result = new_user_ptr;
        } else {
            result = NULL;
        }
        real_free(ptr);
        
    } else {
        // Neither has header: plain realloc
        result = real_realloc(ptr, size);
    }
    
    update_stats_alloc(size, is_sampled);
    
    t_in_wrapper = false;
    return result;
}
EOF
