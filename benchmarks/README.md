# eBPF Memory Profiling Overhead Benchmarks

## Purpose

This benchmark suite provides empirical evidence for the viability of different
eBPF-based memory profiling strategies:

1. **Baseline**: No profiling (reference performance)
2. **High-Overhead**: UProbe on every malloc (microsecond realm - NOT viable)
3. **Optimized**: USDT on sampling path only (nanosecond realm - VIABLE)

## Expected Results

- **Test Case 1 (Baseline)**: Clean execution time
- **Test Case 2 (High-Overhead)**: 2-5μs overhead per allocation
  - At 500M allocs/min: ~40-100% of a CPU core consumed by profiling
- **Test Case 3 (Optimized)**: <100ns overhead per allocation
  - At 500M allocs/min: <1% of a CPU core

## Building

# Install TCMalloc
sudo apt-get install -y libtcmalloc-minimal4 libgoogle-perftools-dev

# Build benchmarks
make all## Running

# Test Case 1: Baseline
./test_case_1_baseline

# Test Case 2: High-Overhead (requires 2 terminals)
# Terminal 1:
./test_case_2_high_overhead
# Terminal 2:
sudo python3 trace_malloc_uprobe.py -p $(pgrep test_case_2)

# Test Case 3: Optimized (requires 2 terminals)
# Terminal 1:
./test_case_3_optimized
# Terminal 2:
sudo python3 trace_sampling_usdt.py -p $(pgrep test_case_3)## Analysis

The Makefile includes an `analyze` target that runs all tests and computes overhead:

make analyze