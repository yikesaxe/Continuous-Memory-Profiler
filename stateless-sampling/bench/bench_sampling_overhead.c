#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
#include <stdbool.h>
#include <math.h>
#include <string.h>

// --- Configuration ---
#define DEFAULT_POISSON_MEAN 4096
#define DEFAULT_HASH_MASK 0xFF

// --- Thread-local State ---
typedef struct {
    int64_t pois_bytes_until_next;
    bool pois_bytes_inited;
    int64_t hash_running_bytes;
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

static long g_poisson_mean = DEFAULT_POISSON_MEAN;

// --- Sampling Functions (copied from sampler.c) ---

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
        tstate.rng_state = (uint64_t)&tstate ^ (uint64_t)time(NULL);
        if (tstate.rng_state == 0) tstate.rng_state = 0xCAFEBABE;
        tstate.rng_init = true;
    }
}

// Geometric distribution for Poisson sampling
static long draw_geometric_bytes(long mean_bytes) {
    if (!tstate.rng_init) init_rng();
    
    double u = (xorshift64(&tstate.rng_state) >> 11) * 0x1.0p-53;
    if (u <= 0.0) u = 1e-12;
    
    return (long)(-log(u) * mean_bytes);
}

// Poisson sampling decision
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

// Stateless Hash sampling decision
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

// --- High-Resolution Timing ---

#if defined(__x86_64__) || defined(__i386__)
// RDTSC-based timing for x86
static inline uint64_t rdtsc_start(void) {
    unsigned cycles_low, cycles_high;
    asm volatile (
        "CPUID\n\t"
        "RDTSC\n\t"
        "mov %%edx, %0\n\t"
        "mov %%eax, %1\n\t"
        : "=r" (cycles_high), "=r" (cycles_low)
        :: "%rax", "%rbx", "%rcx", "%rdx"
    );
    return ((uint64_t)cycles_high << 32) | cycles_low;
}

static inline uint64_t rdtsc_end(void) {
    unsigned cycles_low, cycles_high;
    asm volatile (
        "RDTSCP\n\t"
        "mov %%edx, %0\n\t"
        "mov %%eax, %1\n\t"
        "CPUID\n\t"
        : "=r" (cycles_high), "=r" (cycles_low)
        :: "%rax", "%rbx", "%rcx", "%rdx"
    );
    return ((uint64_t)cycles_high << 32) | cycles_low;
}
#elif defined(__aarch64__)
// ARM64 cycle counter
static inline uint64_t rdtsc_start(void) {
    uint64_t val;
    asm volatile("mrs %0, cntvct_el0" : "=r" (val));
    return val;
}

static inline uint64_t rdtsc_end(void) {
    uint64_t val;
    asm volatile("mrs %0, cntvct_el0" : "=r" (val));
    return val;
}
#else
// Fallback to clock_gettime
static inline uint64_t rdtsc_start(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

static inline uint64_t rdtsc_end(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}
#endif

// --- Statistics ---
typedef struct {
    uint64_t total_calls;
    uint64_t total_cycles;
    uint64_t min_cycles;
    uint64_t max_cycles;
    uint64_t samples_taken;
} TimingStats;

static void init_stats(TimingStats *stats) {
    memset(stats, 0, sizeof(TimingStats));
    stats->min_cycles = UINT64_MAX;
}

static void record_timing(TimingStats *stats, uint64_t cycles, bool sampled) {
    stats->total_calls++;
    stats->total_cycles += cycles;
    if (cycles < stats->min_cycles) stats->min_cycles = cycles;
    if (cycles > stats->max_cycles) stats->max_cycles = cycles;
    if (sampled) stats->samples_taken++;
}

static void print_stats(const char *name, TimingStats *stats) {
    double avg = (double)stats->total_cycles / stats->total_calls;
    double sample_rate = (double)stats->samples_taken / stats->total_calls * 100.0;
    
    printf("%s:\n", name);
    printf("  Total decisions:  %lu\n", stats->total_calls);
    printf("  Samples taken:    %lu (%.2f%%)\n", stats->samples_taken, sample_rate);
    printf("  Avg cycles:       %.4f\n", avg);
    printf("  Min cycles:       %lu\n", stats->min_cycles);
    printf("  Max cycles:       %lu\n", stats->max_cycles);
    printf("\n");
}

// --- Benchmark Workloads ---

void benchmark_uniform_sizes(int num_iterations, size_t alloc_size) {
    printf("=== Benchmark: Uniform Allocation Size (%zu bytes) ===\n", alloc_size);
    printf("Iterations: %d\n\n", num_iterations);
    
    TimingStats stats_poisson, stats_hash, stats_baseline;
    init_stats(&stats_poisson);
    init_stats(&stats_hash);
    init_stats(&stats_baseline);
    
    // Generate test addresses
    void *test_addrs[1000];
    for (int i = 0; i < 1000; i++) {
        test_addrs[i] = (void*)(uintptr_t)(0x7f0000000000ULL + i * 4096);
    }
    
    // Baseline measurement
    printf("Running baseline...\n");
    for (int i = 0; i < num_iterations; i++) {
        uint64_t start = rdtsc_start();
        volatile size_t dummy = 0;
        uint64_t end = rdtsc_end();
        record_timing(&stats_baseline, end - start, false);
    }
    
    // Poisson sampling
    printf("Running Poisson sampling...\n");
    tstate.pois_bytes_inited = true;
    tstate.pois_bytes_until_next = 0;
    for (int i = 0; i < num_iterations; i++) {
        tstate.pois_bytes_until_next += alloc_size;
        
        uint64_t start = rdtsc_start();
        size_t result = sample_poisson(alloc_size);
        uint64_t end = rdtsc_end();
        
        record_timing(&stats_poisson, end - start, result > 0);
        volatile size_t dummy = result;
    }
    
    // Hash sampling
    printf("Running Hash sampling...\n");
    tstate.hash_running_bytes = 0;
    for (int i = 0; i < num_iterations; i++) {
        void *ptr = test_addrs[i % 1000];
        tstate.hash_running_bytes += alloc_size;
        
        uint64_t start = rdtsc_start();
        size_t result = sample_hash(ptr);
        uint64_t end = rdtsc_end();
        
        record_timing(&stats_hash, end - start, result > 0);
        volatile size_t dummy = result;
    }
    
    // Print results
    print_stats("Baseline (no-op)", &stats_baseline);
    print_stats("Poisson Sampling", &stats_poisson);
    print_stats("Hash Sampling", &stats_hash);
    
    double base_avg = (double)stats_baseline.total_cycles / stats_baseline.total_calls;
    double pois_avg = (double)stats_poisson.total_cycles / stats_poisson.total_calls;
    double hash_avg = (double)stats_hash.total_cycles / stats_hash.total_calls;
    
    printf("Overhead Analysis:\n");
    printf("  Poisson overhead: %.4f cycles (%.2fx vs baseline)\n", 
           pois_avg - base_avg, pois_avg / base_avg);
    printf("  Hash overhead:    %.4f cycles (%.2fx vs baseline)\n", 
           hash_avg - base_avg, hash_avg / base_avg);
    printf("  Hash vs Poisson:  %.2fx faster\n", pois_avg / hash_avg);
    printf("\n");
}

void benchmark_mixed_sizes(int num_iterations) {
    printf("=== Benchmark: Mixed Allocation Sizes (16B - 64KB) ===\n");
    printf("Iterations: %d\n\n", num_iterations);
    
    TimingStats stats_poisson, stats_hash;
    init_stats(&stats_poisson);
    init_stats(&stats_hash);
    
    // Generate test data
    void *test_addrs[1000];
    size_t test_sizes[1000];
    for (int i = 0; i < 1000; i++) {
        test_addrs[i] = (void*)(uintptr_t)(0x7f0000000000ULL + i * 4096);
        // Size distribution: 16, 32, 64, 128, 256, 512, 1K, 4K, 16K, 64K
        int size_class = i % 10;
        test_sizes[i] = 16 << size_class;
    }
    
    // Poisson sampling
    printf("Running Poisson sampling...\n");
    tstate.pois_bytes_inited = true;
    tstate.pois_bytes_until_next = 0;
    for (int i = 0; i < num_iterations; i++) {
        size_t size = test_sizes[i % 1000];
        tstate.pois_bytes_until_next += size;
        
        uint64_t start = rdtsc_start();
        size_t result = sample_poisson(size);
        uint64_t end = rdtsc_end();
        
        record_timing(&stats_poisson, end - start, result > 0);
    }
    
    // Hash sampling
    printf("Running Hash sampling...\n");
    tstate.hash_running_bytes = 0;
    for (int i = 0; i < num_iterations; i++) {
        void *ptr = test_addrs[i % 1000];
        size_t size = test_sizes[i % 1000];
        tstate.hash_running_bytes += size;
        
        uint64_t start = rdtsc_start();
        size_t result = sample_hash(ptr);
        uint64_t end = rdtsc_end();
        
        record_timing(&stats_hash, end - start, result > 0);
    }
    
    // Print results
    print_stats("Poisson Sampling", &stats_poisson);
    print_stats("Hash Sampling", &stats_hash);
    
    double pois_avg = (double)stats_poisson.total_cycles / stats_poisson.total_calls;
    double hash_avg = (double)stats_hash.total_cycles / stats_hash.total_calls;
    
    printf("Overhead Analysis:\n");
    printf("  Poisson avg:      %.4f cycles\n", pois_avg);
    printf("  Hash avg:         %.4f cycles\n", hash_avg);
    printf("  Hash vs Poisson:  %.2fx faster\n", pois_avg / hash_avg);
    printf("\n");
}

void benchmark_hot_path(int num_iterations) {
    printf("=== Benchmark: Hot Path (Small Allocations, High Frequency) ===\n");
    printf("Iterations: %d\n\n", num_iterations);
    
    TimingStats stats_poisson, stats_hash;
    init_stats(&stats_poisson);
    init_stats(&stats_hash);
    
    const size_t small_size = 64; // Typical small allocation
    void *test_addr = (void*)0x7f0000001000ULL;
    
    // Poisson sampling - hot path
    printf("Running Poisson sampling...\n");
    tstate.pois_bytes_inited = true;
    tstate.pois_bytes_until_next = 0;
    for (int i = 0; i < num_iterations; i++) {
        tstate.pois_bytes_until_next += small_size;
        
        uint64_t start = rdtsc_start();
        size_t result = sample_poisson(small_size);
        uint64_t end = rdtsc_end();
        
        record_timing(&stats_poisson, end - start, result > 0);
    }
    
    // Hash sampling - hot path
    printf("Running Hash sampling...\n");
    tstate.hash_running_bytes = 0;
    for (int i = 0; i < num_iterations; i++) {
        tstate.hash_running_bytes += small_size;
        
        uint64_t start = rdtsc_start();
        size_t result = sample_hash(test_addr);
        uint64_t end = rdtsc_end();
        
        record_timing(&stats_hash, end - start, result > 0);
    }
    
    // Print results
    print_stats("Poisson Sampling", &stats_poisson);
    print_stats("Hash Sampling", &stats_hash);
    
    double pois_avg = (double)stats_poisson.total_cycles / stats_poisson.total_calls;
    double hash_avg = (double)stats_hash.total_cycles / stats_hash.total_calls;
    
    printf("Overhead Analysis:\n");
    printf("  Poisson avg:      %.2f cycles\n", pois_avg);
    printf("  Hash avg:         %.2f cycles\n", hash_avg);
    printf("  Difference:       %.4f cycles (%.2fx faster)\n", 
           pois_avg - hash_avg, pois_avg / hash_avg);
    printf("\n");
}

// --- Main ---
int main(int argc, char **argv) {
    int num_iterations = 1000000;
    
    if (argc > 1) {
        num_iterations = atoi(argv[1]);
    }
    
    printf("========================================\n");
    printf("  Sampling Decision Overhead Benchmark\n");
    printf("========================================\n\n");
    
    #if defined(__x86_64__) || defined(__i386__)
    printf("Platform: x86_64 (using RDTSC)\n");
    #elif defined(__aarch64__)
    printf("Platform: ARM64 (using CNTVCT)\n");
    #else
    printf("Platform: Generic (using clock_gettime)\n");
    #endif
    printf("Poisson mean: %d bytes\n", DEFAULT_POISSON_MEAN);
    printf("Hash mask: 0x%X (1 in %d)\n\n", DEFAULT_HASH_MASK, DEFAULT_HASH_MASK + 1);
    
    // Run benchmarks
    benchmark_uniform_sizes(num_iterations, 64);    // Small allocations
    benchmark_uniform_sizes(num_iterations, 4096);  // Page-sized allocations
    benchmark_mixed_sizes(num_iterations);
    benchmark_hot_path(num_iterations * 10);  // More iterations for hot path
    
    printf("========================================\n");
    printf("Benchmark complete!\n");
    
    return 0;
}
