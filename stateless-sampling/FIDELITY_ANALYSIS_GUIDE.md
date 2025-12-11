# Live Heap Fidelity Analysis Guide

## Overview

This system measures how accurately stateless sampling techniques can estimate the true "live heap" (memory currently in use) by comparing sampled profiles against ground truth.

## Key Concepts

### 1. Ground Truth Live Heap
- **What**: All currently allocated memory
- **How**: Track every `malloc()` and `free()` call
- **Purpose**: Baseline for comparison

### 2. Sampled Live Heap
- **What**: Weighted estimate based on sampled allocations
- **How**: Only track allocations that pass sampling, with each representing accumulated untracked bytes
- **Purpose**: What a profiler would actually see

### 3. Weighting System

The key insight from your meeting notes:

> "We use the hash to determine whether to sample or not, but we still want the thread local counter remaining bytes to report the total size"

This means:
- **For STATELESS_HASH**: Track `running_bytes` (accumulated size). When hash passes, report accumulated bytes.
- **For POISSON**: Track `bytes_until_next`. When sampling triggers, report `nsamples * mean_interval`.

## How Your Current Implementation Works

Looking at your modified `sampler.c`:

### Thread-Local State
```c
typedef struct {
    int64_t bytes_until_next;  // for poisson
    bool pois_bytes_inited;
    int64_t running_bytes;     // for stateless hash
    uint64_t rng_state;
    bool rng_init;
} ThreadSamplerState;
```

### Sampling Logic

#### STATELESS_HASH
```c
case SCHEME_STATELESS_HASH:
    uintptr_t h = hash(ptr);
    if ((h & MASK) == 0) {
        reported_size = tstate.running_bytes;  // Report accumulated
        tstate.running_bytes = 0;              // Reset counter
    }
    return reported_size;
```

#### POISSON
```c
case SCHEME_POISSON:
    // Accumulate bytes
    remaining_bytes = tstate.bytes_until_next;
    
    // Count how many samples this allocation crosses
    size_t nsamples = remaining_bytes / mean;
    
    // Draw more intervals as needed
    while (remaining_bytes >= 0) {
        remaining_bytes -= draw_geometric(mean);
        nsamples++;
    }
    
    // Report weighted size
    reported_size = nsamples * mean;
    return reported_size;
```

### malloc() Wrapper
```c
void *malloc(size_t size) {
    void *ptr = real_malloc(size);
    
    tstate.running_bytes += size;      // Always accumulate
    tstate.bytes_until_next += size;   // Always accumulate
    
    size_t reported_size = sample(ptr, size);
    
    if (reported_size > 0) {
        printf("MALLOC, %ld.%09ld, %p, %zu\n",
               ts.tv_sec, ts.tv_nsec, ptr, reported_size);
    }
    
    return ptr;
}
```

### free() Wrapper
```c
void free(void *ptr) {
    real_free(ptr);
    
    printf("FREE, %ld.%09ld, %p, -1\n",
           ts.tv_sec, ts.tv_nsec, ptr);
}
```

## The Problem: Missing Ground Truth

**Current Issue**: Your sampler only logs when `reported_size > 0`, which means you're only logging sampled allocations.

**What You Need**: Log BOTH ground truth (every allocation) AND sampled allocations.

## Recommended Log Format

Based on your notes: "EVENT, timestamp, address, actual_size, <tracked by poisson?>, size reported by poisson, <tracked by hash?>, size reported by hash"

### Enhanced CSV Format
```csv
MALLOC, timestamp, address, actual_size, poisson_sampled, poisson_weight, hash_sampled, hash_weight
FREE, timestamp, address, 0, 0, 0, 0, 0
```

Example:
```csv
MALLOC, 1702334567.123456789, 0x7f8a4b000000, 128, 0, 0, 1, 4096
MALLOC, 1702334567.123456790, 0x7f8a4b000080, 64, 1, 4096, 0, 0
FREE, 1702334567.123456791, 0x7f8a4b000000, 0, 0, 0, 0, 0
```

This logs:
1. First malloc (128 bytes): Hash sampled it (weight=4096), Poisson didn't
2. Second malloc (64 bytes): Poisson sampled it (weight=4096), Hash didn't  
3. First free

## Updated sampler.c Strategy

You should modify your `sample()` function to return multiple values:

```c
typedef struct {
    size_t actual_size;
    size_t poisson_weight;
    size_t hash_weight;
} SampleResult;

SampleResult sample(void *ptr, size_t size) {
    SampleResult result = {
        .actual_size = size,
        .poisson_weight = 0,
        .hash_weight = 0
    };
    
    // Always evaluate both schemes
    
    // 1. Poisson sampling
    tstate.bytes_until_next += size;
    if (/* poisson logic */) {
        result.poisson_weight = nsamples * mean;
    }
    
    // 2. Hash sampling
    tstate.running_bytes += size;
    uintptr_t h = hash(ptr);
    if ((h & MASK) == 0) {
        result.hash_weight = tstate.running_bytes;
        tstate.running_bytes = 0;
    }
    
    return result;
}
```

Then in malloc():
```c
void *malloc(size_t size) {
    void *ptr = real_malloc(size);
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    
    SampleResult res = sample(ptr, size);
    
    // Log ALL allocations with both schemes
    printf("MALLOC, %ld.%09ld, %p, %zu, %d, %zu, %d, %zu\n",
           ts.tv_sec, ts.tv_nsec, ptr,
           res.actual_size,
           res.poisson_weight > 0 ? 1 : 0, res.poisson_weight,
           res.hash_weight > 0 ? 1 : 0, res.hash_weight);
    
    return ptr;
}
```

## Using analyze_fidelity.py

Once you have proper logs:

```bash
# Generate logs
LD_PRELOAD=./sampler/libsampler.so \
SAMPLER_SCHEME=STATELESS_HASH \
./bench/bench_alloc_patterns > malloc_log.csv 2>&1

# Analyze
python3 analyze_fidelity.py malloc_log.csv --bins 50 --output-dir results/

# Output:
# - results/live_heap_bytes.png      - Total live bytes over time
# - results/live_heap_count.png      - Number of live allocations
# - results/relative_error.png       - Sampling error percentage
# - results/size_histogram_*.png     - Allocation size distributions
```

## What the Analysis Shows

### 1. Live Heap Bytes Plot
- **Blue line**: Ground truth (actual memory in use)
- **Red line**: Sampled estimate (weighted)
- **Gap**: Shows under/over-estimation

### 2. Relative Error Plot
- **Formula**: `|Sampled - Ground Truth| / Ground Truth × 100%`
- **Good**: < 10% error
- **Warning**: 10-50% error
- **Bad**: > 50% error

### 3. Size Histograms
- Shows distribution of allocation sizes
- Compares ground truth vs sampled at different time points
- Reveals if sampling is biased toward certain sizes

## Validation Metrics

From your notes: "Validate whether 1/256 is actually happening"

The analysis computes:
```
Sample Rate = Sampled Allocations / Total Allocations
Expected: 1/256 ≈ 0.39%
```

For **STATELESS_HASH**: Should be ~0.39% of allocations sampled
For **POISSON (mean=4096)**: Depends on allocation size distribution

## Next Steps

1. **Modify sampler.c** to log both schemes simultaneously (see above)
2. **Run benchmarks** with enhanced logging
3. **Analyze with analyze_fidelity.py** to generate plots
4. **Compare schemes**:
   - Which has lower relative error?
   - Which is more consistent across workloads?
   - Does hash really achieve 1/256 sample rate?

## Workload-Specific Analysis

Run on all your benchmarks:

```bash
# Monotonic
LD_PRELOAD=./sampler/libsampler.so ./bench/bench_alloc_patterns mono > mono.csv
python3 analyze_fidelity.py mono.csv --output-dir results/mono/

# High reuse
LD_PRELOAD=./sampler/libsampler.so ./bench/bench_alloc_patterns reuse > reuse.csv
python3 analyze_fidelity.py reuse.csv --output-dir results/reuse/

# Curl build
LD_PRELOAD=./sampler/libsampler.so make -C curl > curl.csv 2>&1
python3 analyze_fidelity.py curl.csv --output-dir results/curl/
```

## Understanding ddprof's Approach

From your notes, ddprof does:

```
track_allocation_s(addr, size, tl_state):
    tl_state.remaining_bytes += size
    if (tl_state.remaining_bytes < 0) return  # Skip until initialized
    track_allocation(addr, size, tl_state)

track_allocation(addr, size, tl_state):
    remaining_bytes = tl_state.remaining_bytes
    
    if (!initialized):
        remaining_bytes -= draw_geometric(mean)
        initialized = true
        
    # Count samples
    nsamples = 0
    while (remaining_bytes >= 0):
        remaining_bytes -= draw_geometric(mean)
        nsamples++
    
    tl_state.remaining_bytes = remaining_bytes
    total_size = nsamples * mean
    
    # Track this allocation with weighted size
    push_alloc_sample(addr, total_size)
```

This is almost exactly what you've implemented in your POISSON case! The key insight is:
- Accumulate bytes in thread-local state
- When threshold crossed, report weighted size
- Each sample represents `mean` bytes on average

## Common Pitfalls

1. **Not logging actual size**: You need ground truth size for every allocation
2. **Forgetting to reset counters**: After sampling, reset accumulated bytes
3. **Thread safety**: Make sure thread-local state is truly per-thread
4. **Timestamp precision**: Use nanosecond timestamps to maintain order
5. **Large logs**: Real workloads generate huge logs, consider binary format

## Future Enhancements

- Binary log format (more efficient)
- Real-time analysis (process logs as they're generated)
- Multi-threaded log parsing
- Interactive visualizations
- Comparison across multiple schemes in one plot

