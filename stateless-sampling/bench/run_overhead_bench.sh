#!/bin/bash
# Convenience script to run sampling overhead benchmarks

BENCH=./bench_sampling_overhead

if [ ! -f "$BENCH" ]; then
    echo "Benchmark not compiled. Building..."
    make bench_sampling_overhead
fi

echo "=========================================="
echo "Running Sampling Overhead Benchmarks"
echo "=========================================="
echo ""

# Quick test (100K iterations)
echo "1. Quick test (100K iterations):"
$BENCH 100000
echo ""

# Longer test for more accurate measurements (1M iterations)
echo "=========================================="
echo "2. Detailed test (1M iterations):"
$BENCH 1000000
echo ""

# High-frequency simulation (10M iterations)
echo "=========================================="
echo "3. High-frequency test (10M iterations):"
$BENCH 10000000
echo ""

echo "=========================================="
echo "Results saved to terminal output"
echo "See SAMPLING_OVERHEAD_RESULTS.md for interpretation"
echo "=========================================="
