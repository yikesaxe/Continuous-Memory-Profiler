#ifndef SAMPLER_SAMPLE_HEADERS_H
#define SAMPLER_SAMPLE_HEADERS_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

// Header structure (only on sampled allocations)
#define SAMPLE_MAGIC 0xDDBEEFCAFEBABE01ULL
#define HEADER_SIZE 16
#define FLAG_SAMPLED 0x1

typedef struct {
    uint64_t magic;
    uint32_t flags;
    uint32_t reserved;  // Original size
} SampleHeader;

// Sampling schemes
typedef enum {
    SCHEME_NONE = 0,
    SCHEME_SAMPLE_HEADERS_POISSON_MAP = 1,
    SCHEME_SAMPLE_HEADERS_HASH_MAP = 2,
    SCHEME_SAMPLE_HEADERS_EBPF_INSPIRED = 3,
} SampleHeadersScheme;

// Hash table for tracking sampled allocations
#define HASH_TABLE_SIZE 65536
#define HASH_TABLE_MASK (HASH_TABLE_SIZE - 1)

typedef struct HashEntry {
    void *key;                // User pointer
    void *header_ptr;         // Header pointer (for freeing)
    struct HashEntry *next;
} HashEntry;

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
    
    // Map-specific metrics
    uint64_t map_inserts;
    uint64_t map_lookups;
    uint64_t map_deletes;
    uint64_t map_current_size;
    uint64_t map_peak_size;
    
    #define NUM_SIZE_BINS 10
    uint64_t size_bin_total[NUM_SIZE_BINS];
    uint64_t size_bin_sampled[NUM_SIZE_BINS];
} SampleHeadersStats;

#define WINDOW_SIZE 100000
#define DEFAULT_HASH_MASK 0xFF
#define DEFAULT_POISSON_MEAN 4096

#endif
