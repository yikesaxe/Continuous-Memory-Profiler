#ifndef SAMPLER_STATELESS_H
#define SAMPLER_STATELESS_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

typedef enum {
    SCHEME_NONE = 0,
    SCHEME_STATELESS_HASH_XOR = 1,
    SCHEME_STATELESS_HASH_SPLITMIX = 2,
    SCHEME_STATELESS_HASH_MURMURISH = 3,
    SCHEME_STATELESS_POISSON_BERNOULLI = 4,
} StatelessSamplingScheme;

typedef struct {
    uint64_t total_allocs;
    uint64_t total_bytes_alloc;
    uint64_t sampled_allocs;
    uint64_t sampled_bytes_alloc;
    uint64_t total_frees;
    uint64_t sampled_frees_estimate;
    uint64_t window_alloc_count;
    uint64_t window_sampled_count;
    uint64_t windows_total;
    uint64_t windows_zero_sampled;
    #define NUM_SIZE_BINS 10
    uint64_t size_bin_total[NUM_SIZE_BINS];
    uint64_t size_bin_sampled[NUM_SIZE_BINS];
} StatelessStats;

#define WINDOW_SIZE 100000
#define DEFAULT_HASH_MASK 0xFF
#define DEFAULT_POISSON_MEAN 4096

#endif
