/*
 * malloc_wrapper.c - LD_PRELOAD wrapper that adds USDT probes to malloc/free
 * 
 * Usage: LD_PRELOAD=./malloc_wrapper.so ./any_program
 * 
 * This intercepts malloc/free calls and adds sampling-based USDT probes
 * Works with ANY binary without recompilation!
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <sys/sdt.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>

// Sampling configuration
#define SAMPLE_THRESHOLD_BYTES (512 * 1024)  // Sample every 512KB

// Per-thread sampling state
static __thread size_t bytes_until_sample = SAMPLE_THRESHOLD_BYTES;
static __thread size_t sample_count = 0;

// Function pointers to real malloc/free
static void* (*real_malloc)(size_t) = NULL;
static void (*real_free)(void*) = NULL;
static void* (*real_calloc)(size_t, size_t) = NULL;
static void* (*real_realloc)(void*, size_t) = NULL;

// Initialization flag
static int initialized = 0;
static pthread_mutex_t init_lock = PTHREAD_MUTEX_INITIALIZER;

// Initialize function pointers
static void init_wrapper(void) {
    pthread_mutex_lock(&init_lock);
    if (!initialized) {
        real_malloc = dlsym(RTLD_NEXT, "malloc");
        real_free = dlsym(RTLD_NEXT, "free");
        real_calloc = dlsym(RTLD_NEXT, "calloc");
        real_realloc = dlsym(RTLD_NEXT, "realloc");
        
        if (!real_malloc || !real_free || !real_calloc || !real_realloc) {
            fprintf(stderr, "Error: Failed to find real malloc/free functions\n");
            exit(1);
        }
        
        initialized = 1;
        fprintf(stderr, "[malloc_wrapper] Initialized with %zu byte sampling threshold\n", 
                (size_t)SAMPLE_THRESHOLD_BYTES);
    }
    pthread_mutex_unlock(&init_lock);
}

// Intercepted malloc
void* malloc(size_t size) {
    if (!initialized) {
        init_wrapper();
    }
    
    // Call real malloc
    void* ptr = real_malloc(size);
    
    // Fast path: cheap integer comparison
    if (bytes_until_sample > size) {
        bytes_until_sample -= size;
        return ptr;
    }
    
    // Sampling path: fire USDT probe
    bytes_until_sample = SAMPLE_THRESHOLD_BYTES;
    sample_count++;
    
    // USDT probe - only fires on sampled allocations
    DTRACE_PROBE3(malloc_wrapper, sample_alloc, size, ptr, sample_count);
    
    return ptr;
}

// Intercepted calloc
void* calloc(size_t nmemb, size_t size) {
    if (!initialized) {
        init_wrapper();
    }
    
    void* ptr = real_calloc(nmemb, size);
    
    size_t total_size = nmemb * size;
    
    // Same sampling logic as malloc
    if (bytes_until_sample > total_size) {
        bytes_until_sample -= total_size;
        return ptr;
    }
    
    bytes_until_sample = SAMPLE_THRESHOLD_BYTES;
    sample_count++;
    
    DTRACE_PROBE3(malloc_wrapper, sample_alloc, total_size, ptr, sample_count);
    
    return ptr;
}

// Intercepted realloc
void* realloc(void* old_ptr, size_t size) {
    if (!initialized) {
        init_wrapper();
    }
    
    void* ptr = real_realloc(old_ptr, size);
    
    // Same sampling logic
    if (bytes_until_sample > size) {
        bytes_until_sample -= size;
        return ptr;
    }
    
    bytes_until_sample = SAMPLE_THRESHOLD_BYTES;
    sample_count++;
    
    DTRACE_PROBE3(malloc_wrapper, sample_alloc, size, ptr, sample_count);
    
    return ptr;
}

// Intercepted free (no probe - keeping it fast)
void free(void* ptr) {
    if (!initialized) {
        init_wrapper();
    }
    
    real_free(ptr);
}

// Constructor - runs when library is loaded
__attribute__((constructor))
static void wrapper_constructor(void) {
    fprintf(stderr, "[malloc_wrapper] LD_PRELOAD wrapper loaded\n");
    fprintf(stderr, "[malloc_wrapper] USDT probes will fire on sampling path\n");
}

// Destructor - runs when library is unloaded
__attribute__((destructor))
static void wrapper_destructor(void) {
    fprintf(stderr, "[malloc_wrapper] Wrapper unloaded (thread samples: %zu)\n", sample_count);
}

