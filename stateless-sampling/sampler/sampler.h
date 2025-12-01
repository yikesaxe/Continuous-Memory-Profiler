#ifndef SAMPLER_H
#define SAMPLER_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

// --- Configuration Constants ---

// Magic number to identify our headers (random 64-bit value)
#define SAMPLE_MAGIC 0xDDBEEFCAFEBABE01ULL

// Header flags
#define FLAG_SAMPLED 0x1

// Default Sampling settings
#define DEFAULT_POISSON_MEAN 4096      // Target mean bytes between samples
#define DEFAULT_HASH_MASK    0xFF      // 1 in 256 for hash sampling
#define HYBRID_SMALL_THRESH  256       // Allocations smaller than this use Poisson in hybrid mode

// Dead zone window size
#define WINDOW_SIZE 100000

// --- Data Structures ---

// The header placed before every allocation
// 16 bytes to maintain 16-byte alignment of the user pointer
typedef struct __attribute__((aligned(16))) SampleHeader {
    uint64_t magic;    // Identification
    uint32_t flags;    // Metadata (is it sampled?)
    uint32_t reserved; // Padding/Unused
} SampleHeader;

#define HEADER_SIZE ((size_t)sizeof(SampleHeader))

// Sampling schemes
typedef enum SamplingScheme {
    SCHEME_NONE = 0,
    SCHEME_STATELESS_HASH = 1,
    SCHEME_POISSON_HEADER = 2,
    SCHEME_HYBRID_SMALL_POISSON_LARGE_HASH = 3,
    SCHEME_PAGE_HASH = 4
} SamplingScheme;

// Statistics bins
#define NUM_SIZE_BINS 10
// Bin boundaries (upper inclusive): 32, 64, 128, 256, 512, 1024, 4096, 16384, 65536, >65536

// Global Statistics Structure
typedef struct Stats {
    // Allocation counts
    uint64_t total_allocs;
    uint64_t total_frees;
    uint64_t total_bytes_alloc;
    uint64_t total_bytes_freed;

    // Sampled counts
    uint64_t sampled_allocs;
    uint64_t sampled_frees;
    uint64_t sampled_bytes_alloc;
    uint64_t sampled_bytes_freed;

    // Dead zone tracking
    uint64_t window_alloc_count;    // Current progress in window
    uint64_t window_sampled_count;  // Samples in current window
    uint64_t windows_total;         // Total windows completed
    uint64_t windows_zero_sampled;  // Windows with 0 samples

    // Page-based approximate metrics (for PAGE_HASH)
    uint64_t approx_unique_pages;
    uint64_t approx_sampled_pages;

    // Size distribution
    uint64_t size_bin_total[NUM_SIZE_BINS];
    uint64_t size_bin_sampled[NUM_SIZE_BINS];

} Stats;

#endif // SAMPLER_H

