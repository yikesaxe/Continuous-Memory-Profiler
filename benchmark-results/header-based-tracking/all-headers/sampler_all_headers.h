#ifndef SAMPLER_ALL_HEADERS_H
#define SAMPLER_ALL_HEADERS_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

// Header structure (same as original)
#define SAMPLE_MAGIC 0xDDBEEFCAFEBABE01ULL
#define HEADER_SIZE 16
#define FLAG_SAMPLED 0x1

typedef struct {
    uint64_t magic;
    uint32_t flags;
    uint32_t reserved;  // Stores original size
} SampleHeader;

// Sampling schemes
typedef enum {
    SCHEME_NONE = 0,
    SCHEME_HEADER_HASH = 1,
    SCHEME_HEADER_PAGE_HASH = 2,
    SCHEME_HEADER_POISSON_BYTES = 3,
    SCHEME_HEADER_HYBRID = 4,
} AllHeadersSamplingScheme;

// Statistics
typedef struct {
    uint64_t total_allocs;
    uint64_t total_bytes_alloc;
    uint64_t sampled_allocs;
    uint64_t sampled_bytes_alloc;
    uint64_t total_frees;
    uint64_t sampled_frees;
    uint64_t sampled_bytes_freed;
    uint64_t window_alloc_count;
    uint64_t window_sampled_count;
    uint64_t windows_total;
    uint64_t windows_zero_sampled;
    uint64_t approx_unique_pages;
    uint64_t approx_sampled_pages;
    #define NUM_SIZE_BINS 10
    uint64_t size_bin_total[NUM_SIZE_BINS];
    uint64_t size_bin_sampled[NUM_SIZE_BINS];
} AllHeadersStats;

#define WINDOW_SIZE 100000
#define DEFAULT_HASH_MASK 0xFF
#define DEFAULT_POISSON_MEAN 4096
#define HYBRID_SMALL_THRESH 256

#endif
