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
#include <stdbool.h>
/*
 * Synthetic Benchmark for Memory Allocator Sampling
 * 
 * Workloads:
 * 1. Monotonic Heap: Alloc N, Free 95%, Leak 5%. Tests leak detection.
 * 2. Steady Pool: Alloc/Free churn in a pool. Tests stability.
 * 3. High Reuse: Repeatedly alloc/free same slots. Tests sampling bias on reused addresses.
 */

// Helper to parse args
static int parse_int(const char *str) {
    return atoi(str);
}

static size_t rand_size(size_t min, size_t max) {
    if (min == max) return min;
    return min + (rand() % (max - min + 1));
}

// Workload 1: Monotonic Heap with Leaks
// Allocates N items. Frees 95% of them. Leaks 5%.
void workload_monotonic_leaks(int N, size_t min_size, size_t max_size) {
    void **ptrs = malloc(N * sizeof(void*));
    if (!ptrs) abort();

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    printf("START, %ld.%09ld, -1, -1\n",
        ts.tv_sec, ts.tv_nsec
    );
    
    // Allocate all
    for (int i = 0; i < N; i++) {
        ptrs[i] = malloc(rand_size(min_size, max_size));
        // Optional: touch memory
        if (ptrs[i]) *(char*)ptrs[i] = 1; 
    }

    // Free 95%, leak 5%
    // We purposely leak the last 5% to simulate "recent" leaks or permanent structure buildup
    int cutoff = (int)(N * 0.95);
    for (int i = 0; i < cutoff; i++) {
        if (ptrs[i]) free(ptrs[i]);
    }
    
    clock_gettime(CLOCK_REALTIME, &ts);

    printf("END, %ld.%09ld, -1, -1\n",
        ts.tv_sec, ts.tv_nsec
    );
    free(ptrs); // The array itself is freed, but the leaked pointers are lost
}

// Workload 2: Steady State Pool with Leaks
void workload_steady_leaks(int iterations, int pool_size, size_t min_size, size_t max_size, int alloc_prob_percent) {
    void **pool = calloc(pool_size, sizeof(void*));
    // To track which indices are "leaked" (permanently occupied)
    bool *leaked = calloc(pool_size, sizeof(bool));

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);

    printf("START, %ld.%09ld, -1, -1\n",
        ts.tv_sec, ts.tv_nsec
    );


    for (int i = 0; i < iterations; i++) {
        // Iterate through pool
        for (int p = 0; p < pool_size; p++) {
            if (leaked[p]) continue;

            if (pool[p] == NULL) {
                // Try allocate
                if ((rand() % 100) < alloc_prob_percent) {
                    pool[p] = malloc(rand_size(min_size, max_size));
                    if (pool[p]) *(char*)pool[p] = 0; // touch
                }
            } else {
                // Try free
                if ((rand() % 100) < (100 - alloc_prob_percent)) {
                    free(pool[p]);
                    pool[p] = NULL;
                }
            }
        }

        // Halfway through, mark random slots as "leaky" - they will never be freed
        if (i == iterations / 2) {
            int leaks_to_create = pool_size / 20; // 5% leaks
            printf("  [Iter %d] Injecting %d leaks...\n", i, leaks_to_create);
            for (int k = 0; k < leaks_to_create; k++) {
                int idx = rand() % pool_size;
                // If it's allocated, mark it. If not, alloc it and mark it.
                if (pool[idx] == NULL) {
                    pool[idx] = malloc(rand_size(min_size, max_size));
                }
                if (pool[idx]) leaked[idx] = true;
            }
        }
    }

    // At end, free non-leaked items
    for (int p = 0; p < pool_size; p++) {
        if (pool[p] && !leaked[p]) {
            free(pool[p]);
        }
    }

    clock_gettime(CLOCK_REALTIME, &ts);

    printf("END, %ld.%09ld, -1, -1\n",
        ts.tv_sec, ts.tv_nsec
    );
    free(leaked);
    free(pool);
}

// Workload 3: High Address Reuse
// Designed to stress test stateless hashing by reusing a small set of addresses.
void workload_high_reuse(int num_hot_slots, int iterations, size_t min_size, size_t max_size) {
    printf("Running Workload 3: High Reuse (Slots=%d, Iter=%d)\n", num_hot_slots, iterations);

    void **hot = calloc(num_hot_slots, sizeof(void*));
    bool *leaky = calloc(num_hot_slots, sizeof(bool));

    // Initialize hot set
    for (int i = 0; i < num_hot_slots; i++) {
        hot[i] = malloc(rand_size(min_size, max_size));
    }

    // Churn loop
    for (int i = 0; i < iterations; i++) {
        int idx = rand() % num_hot_slots;
        
        // Skip if this slot became leaky
        if (leaky[idx]) continue;

        // Free and immediately re-allocate
        // This encourages the allocator to return the same address (LIFO behavior common in malloc)
        if (hot[idx]) free(hot[idx]);
        
        hot[idx] = malloc(rand_size(min_size, max_size));
        if (hot[idx]) *(char*)hot[idx] = 1;

        // Halfway through, mark 5% as leaky
        if (i == iterations / 2) {
            int leaks = num_hot_slots / 20;
            printf("  [Iter %d] Marking %d slots as leaky...\n", i, leaks);
            for (int k = 0; k < leaks; k++) {
                int l_idx = rand() % num_hot_slots;
                leaky[l_idx] = true;
            }
        }
    }

    // Cleanup non-leaky
    int leaked_count = 0;
    for (int i = 0; i < num_hot_slots; i++) {
        if (!leaky[i] && hot[i]) {
            free(hot[i]);
        }
        if (leaky[i]) leaked_count++;
    }

    printf("  Finished. %d slots leaked.\n", leaked_count);
    free(hot);
    free(leaky);
}

void leaky_function() {
    for (int i = 0; i < 10000; i++) {
        void *ptr = malloc(rand_size(16, 4096));
        // 10% free
        if (ptr && i % 10 == 0) {
            free(ptr);
        }

        // 50% free
        // if (ptr && i % 2 == 0) {
        //     free(ptr);
        // }

        // 90% free
        // if (ptr && i % 10 != 0) {
        //     free(ptr);
        // }
    }
}

// Workload 4: Repeat Leaks
void workload_repeat_leaks() {
    for (int i = 0; i < 10; i++) {
        leaky_function();
    }
}

int main(int argc, char **argv) {
    srand(time(NULL));

    if (argc < 2) {
        fprintf(stderr, "Usage:\n");
        fprintf(stderr, "  %s 1 N min max               (Monotonic)\n", argv[0]);
        fprintf(stderr, "  %s 2 iter pool min max prob  (Steady)\n", argv[0]);
        fprintf(stderr, "  %s 4 slots iter min max      (High Reuse)\n", argv[0]);
        return 1;
    }

    int mode = parse_int(argv[1]);

    if (mode == 1) {
        if (argc < 5) return 1;
        int N = parse_int(argv[2]);
        size_t min = parse_int(argv[3]);
        size_t max = parse_int(argv[4]);
        workload_monotonic_leaks(N, min, max);
    } else if (mode == 2) {
        if (argc < 7) return 1;
        int iter = parse_int(argv[2]);
        int pool = parse_int(argv[3]);
        size_t min = parse_int(argv[4]);
        size_t max = parse_int(argv[5]);
        int prob = parse_int(argv[6]);
        workload_steady_leaks(iter, pool, min, max, prob);
    } else if (mode == 3) {
        workload_repeat_leaks();
    } else if (mode == 4) { // Matches prompt "Workload 3" but user asked for cmd "./bench 4"
        if (argc < 6) return 1;
        int slots = parse_int(argv[2]);
        int iter = parse_int(argv[3]);
        size_t min = parse_int(argv[4]);
        size_t max = parse_int(argv[5]);
        workload_high_reuse(slots, iter, min, max);
    }

    return 0;
}
