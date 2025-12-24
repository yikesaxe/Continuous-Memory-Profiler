# Timing Benchmark Guide

This guide shows you how to measure sampling decision overhead on your real allocation workloads.

## Overview

You now have two complementary benchmarking approaches:

1. **`bench_sampling_overhead`** - Microbenchmark (isolated, synthetic)
2. **`bench_alloc_patterns` with timed sampler** - Real workloads (realistic overhead)

## Quick Start

### Option 1: Run All Benchmarks

```bash
cd /home/axel/Workspace/Continous-Memory-Profiler/stateless-sampling/bench
./run_timed_benchmarks.sh
```

This will:
- Run all 3 allocation patterns (Monotonic, Steady, High Reuse)
- Test both Poisson and Hash sampling
- Save timing results to `timing_*.txt` files
- Print a summary

### Option 2: Run Individual Tests

```bash
# Build first
make bench_alloc_patterns
cd ../sampler && make libsampler_timed.so && cd ../bench

# Enable timing and preload the timed sampler
export SAMPLER_TIMING=1
export LD_PRELOAD="../sampler/libsampler_timed.so"

# Test Poisson sampling on monotonic workload
export SAMPLER_SCHEME=POISSON
./bench_alloc_patterns 1 100000 64 4096 > /dev/null

# Test Hash sampling on the same workload
export SAMPLER_SCHEME=STATELESS_HASH
./bench_alloc_patterns 1 100000 64 4096 > /dev/null

# Test both schemes simultaneously (COMBINED mode)
export SAMPLER_SCHEME=COMBINED
./bench_alloc_patterns 1 100000 64 4096 > /dev/null
```

The timing statistics will be printed to stderr at program exit.

## Workload Descriptions

### 1. Monotonic Heap (`mode 1`)
```bash
./bench_alloc_patterns 1 <N> <min_size> <max_size>
```
- Allocates N items
- Frees 95%, leaks 5%
- Tests: Initial heap buildup and leak detection

**Example:**
```bash
./bench_alloc_patterns 1 100000 64 4096
```

### 2. Steady State Pool (`mode 2`)
```bash
./bench_alloc_patterns 2 <iterations> <pool_size> <min_size> <max_size> <alloc_prob>
```
- Maintains a pool with random alloc/free churn
- Introduces leaks midway through
- Tests: Long-running steady state behavior

**Example:**
```bash
./bench_alloc_patterns 2 1000 1000 64 4096 50
```

### 3. High Address Reuse (`mode 4`)
```bash
./bench_alloc_patterns 4 <slots> <iterations> <min_size> <max_size>
```
- Repeatedly frees and allocates same slots
- Encourages allocator to reuse addresses
- Tests: Hash sampling vulnerability to address reuse

**Example:**
```bash
./bench_alloc_patterns 4 500 100000 64 4096
```

## Understanding the Output

When timing is enabled, you'll see output like this at program exit:

```
========================================
SAMPLING DECISION TIMING STATISTICS
========================================
Platform: ARM64 (CNTVCT cycles)

Poisson Sampling:
  Total decisions:  100000
  Samples taken:    23456 (23.46%)
  Avg cycles:       0.28
  Min cycles:       0
  Max cycles:       646
  Total cycles:     28000

Hash Sampling:
  Total decisions:  100000
  Samples taken:    400 (0.40%)
  Avg cycles:       0.01
  Min cycles:       0
  Max cycles:       2
  Total cycles:     1000

Overhead Comparison:
  Hash vs Poisson speedup: 28.00x
  Absolute difference:     0.27 cycles
========================================
```

### Key Metrics

| Metric | Meaning |
|--------|---------|
| **Total decisions** | Number of malloc calls processed |
| **Samples taken** | How many allocations were sampled |
| **Avg cycles** | Average CPU cycles per sampling decision |
| **Min/Max cycles** | Range of decision costs |
| **Total cycles** | Cumulative overhead |

### What to Look For

1. **Average cycles:** Lower is better. Hash should be ~3-60x faster than Poisson.
2. **Sample rate:** Poisson typically samples 1-30%, Hash samples ~0.4% (1/256)
3. **Total cycles:** The overall time cost of all sampling decisions
4. **Speedup:** Hash vs Poisson ratio shows relative efficiency

## Comparing Results

After running tests, use the summary script:

```bash
./summarize_timing.sh
```

This will create a side-by-side comparison:

```
========================================
  Sampling Overhead Summary
========================================

-------------------------------------------
Monotonic Heap Workload
-------------------------------------------
Poisson:
  Decisions: 100000
  Samples:   23456
  Avg/call:  0.28 cycles
  Total:     28000 cycles

Hash:
  Decisions: 100000
  Samples:   400
  Avg/call:  0.01 cycles
  Total:     1000 cycles

Hash is 28.00x faster (saves 0.27 cycles/decision)
```

## Advanced Usage

### Custom Workload Parameters

Edit `run_timed_benchmarks.sh` to adjust:
- Number of allocations
- Size ranges
- Iteration counts

### Testing Different Sampling Rates

Modify Poisson mean or Hash mask:

```bash
export SAMPLER_POISSON_MEAN_BYTES=8192  # Less frequent sampling
export SAMPLER_TIMING=1
export SAMPLER_SCHEME=POISSON
export LD_PRELOAD="../sampler/libsampler_timed.so"
./bench_alloc_patterns 1 100000 64 4096 > /dev/null
```

### Collecting Traces

If you want both timing AND trace data:

```bash
export SAMPLER_TIMING=1
export SAMPLER_SCHEME=COMBINED
export LD_PRELOAD="../sampler/libsampler_timed.so"
./bench_alloc_patterns 1 100000 64 4096 > trace.log 2> timing.txt
```

Now you have:
- `trace.log` - Full malloc/free trace
- `timing.txt` - Timing statistics

## Interpreting Results for Your Use Case

### For High-Throughput Systems (Redis, Memcached)
- Focus on **avg cycles** - every cycle counts at scale
- Look at **hot path** scenarios (small, frequent allocations)
- Hash's constant-time overhead is advantageous

### For Leak Detection
- Look at **sample rate** - Poisson gives better coverage
- Consider **total cycles** over long runs
- Poisson's statistical properties may justify overhead

### For Hybrid Approaches
- Compare overhead on different allocation sizes
- Consider using Hash for <256B, Poisson for larger allocations
- Test with your actual workload patterns

## Troubleshooting

### "undefined symbol" errors
Make sure the timed sampler is built:
```bash
cd ../sampler && make libsampler_timed.so
```

### No timing output
Check that `SAMPLER_TIMING=1` is set:
```bash
echo $SAMPLER_TIMING
```

### Timing seems wrong
- Ensure you're redirecting stderr: `2> timing.txt`
- Timing stats print at program exit, not during execution

### Results don't match microbenchmark
This is expected! Real workloads have:
- Cache effects
- Different allocation patterns
- Syscall overhead
- Memory pressure

The microbenchmark isolates just the sampling logic. The real workload tests include these real-world factors.

## File Structure

```
bench/
├── bench_sampling_overhead.c       # Microbenchmark (isolated)
├── bench_sampling_overhead         # Compiled microbenchmark
├── bench_alloc_patterns.c          # Real workload patterns
├── bench_alloc_patterns            # Compiled workload
├── run_timed_benchmarks.sh         # Run all tests
├── summarize_timing.sh             # Compare results
├── timing_*.txt                    # Results (generated)
└── TIMING_BENCHMARK_GUIDE.md       # This file

sampler/
├── sampler_timed.c                 # Instrumented sampler
└── libsampler_timed.so             # Compiled library
```

## Next Steps

1. **Run the full benchmark suite:**
   ```bash
   ./run_timed_benchmarks.sh
   ```

2. **Review results:**
   ```bash
   ./summarize_timing.sh
   ```

3. **Analyze for your use case:**
   - Is Hash's speedup significant for your workload?
   - Does Poisson's better coverage justify the overhead?
   - Should you use a hybrid approach?

4. **Test with real applications:**
   ```bash
   export SAMPLER_TIMING=1
   export SAMPLER_SCHEME=COMBINED
   export LD_PRELOAD="/path/to/libsampler_timed.so"
   ./your_application
   ```

## References

- `SAMPLING_OVERHEAD_RESULTS.md` - Microbenchmark results and analysis
- `bench_alloc_patterns.c` - Workload source code
- `sampler_timed.c` - Instrumentation implementation
