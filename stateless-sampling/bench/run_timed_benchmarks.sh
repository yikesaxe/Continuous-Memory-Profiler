#!/bin/bash
# Run bench_alloc_patterns workloads with timing-instrumented sampler

set -e

# Build if needed
if [ ! -f bench_alloc_patterns ]; then
    echo "Building bench_alloc_patterns..."
    make bench_alloc_patterns
fi

if [ ! -f ../sampler/libsampler_timed.so ]; then
    echo "Building timed sampler..."
    cd ../sampler && make libsampler_timed.so && cd ../bench
fi

SAMPLER_LIB="../sampler/libsampler_timed.so"
BENCH="./bench_alloc_patterns"

echo "=========================================="
echo "  Allocation Pattern Timing Benchmarks"
echo "=========================================="
echo ""

# Configuration
export SAMPLER_TIMING=1  # Enable timing measurements
export LD_PRELOAD="$SAMPLER_LIB"

# Workload parameters
MONO_N=100000
MONO_MIN=64
MONO_MAX=4096

STEADY_ITER=1000
STEADY_POOL=1000
STEADY_MIN=64
STEADY_MAX=4096
STEADY_PROB=50

REUSE_SLOTS=500
REUSE_ITER=100000
REUSE_MIN=64
REUSE_MAX=4096

echo "-------------------------------------------"
echo "Test 1: Monotonic Heap (Poisson)"
echo "  Allocations: $MONO_N"
echo "  Sizes: ${MONO_MIN}B - ${MONO_MAX}B"
echo "-------------------------------------------"
export SAMPLER_SCHEME=POISSON
$BENCH 1 $MONO_N $MONO_MIN $MONO_MAX > /dev/null 2> timing_mono_poisson.txt
echo "✓ Done. Timing saved to timing_mono_poisson.txt"
echo ""

echo "-------------------------------------------"
echo "Test 2: Monotonic Heap (Hash)"
echo "  Allocations: $MONO_N"
echo "  Sizes: ${MONO_MIN}B - ${MONO_MAX}B"
echo "-------------------------------------------"
export SAMPLER_SCHEME=STATELESS_HASH
$BENCH 1 $MONO_N $MONO_MIN $MONO_MAX > /dev/null 2> timing_mono_hash.txt
echo "✓ Done. Timing saved to timing_mono_hash.txt"
echo ""

echo "-------------------------------------------"
echo "Test 3: Steady State Pool (Poisson)"
echo "  Iterations: $STEADY_ITER, Pool: $STEADY_POOL"
echo "  Sizes: ${STEADY_MIN}B - ${STEADY_MAX}B"
echo "-------------------------------------------"
export SAMPLER_SCHEME=POISSON
$BENCH 2 $STEADY_ITER $STEADY_POOL $STEADY_MIN $STEADY_MAX $STEADY_PROB > /dev/null 2> timing_steady_poisson.txt
echo "✓ Done. Timing saved to timing_steady_poisson.txt"
echo ""

echo "-------------------------------------------"
echo "Test 4: Steady State Pool (Hash)"
echo "  Iterations: $STEADY_ITER, Pool: $STEADY_POOL"
echo "  Sizes: ${STEADY_MIN}B - ${STEADY_MAX}B"
echo "-------------------------------------------"
export SAMPLER_SCHEME=STATELESS_HASH
$BENCH 2 $STEADY_ITER $STEADY_POOL $STEADY_MIN $STEADY_MAX $STEADY_PROB > /dev/null 2> timing_steady_hash.txt
echo "✓ Done. Timing saved to timing_steady_hash.txt"
echo ""

echo "-------------------------------------------"
echo "Test 5: High Address Reuse (Poisson)"
echo "  Slots: $REUSE_SLOTS, Iterations: $REUSE_ITER"
echo "  Sizes: ${REUSE_MIN}B - ${REUSE_MAX}B"
echo "-------------------------------------------"
export SAMPLER_SCHEME=POISSON
$BENCH 4 $REUSE_SLOTS $REUSE_ITER $REUSE_MIN $REUSE_MAX > /dev/null 2> timing_reuse_poisson.txt
echo "✓ Done. Timing saved to timing_reuse_poisson.txt"
echo ""

echo "-------------------------------------------"
echo "Test 6: High Address Reuse (Hash)"
echo "  Slots: $REUSE_SLOTS, Iterations: $REUSE_ITER"
echo "  Sizes: ${REUSE_MIN}B - ${REUSE_MAX}B"
echo "-------------------------------------------"
export SAMPLER_SCHEME=STATELESS_HASH
$BENCH 4 $REUSE_SLOTS $REUSE_ITER $REUSE_MIN $REUSE_MAX > /dev/null 2> timing_reuse_hash.txt
echo "✓ Done. Timing saved to timing_reuse_hash.txt"
echo ""

echo "-------------------------------------------"
echo "Test 7: Combined Mode (Both schemes)"
echo "  Using Monotonic workload"
echo "-------------------------------------------"
export SAMPLER_SCHEME=COMBINED
$BENCH 1 $MONO_N $MONO_MIN $MONO_MAX > /dev/null 2> timing_combined.txt
echo "✓ Done. Timing saved to timing_combined.txt"
echo ""

echo "=========================================="
echo "All benchmarks complete!"
echo ""
echo "Results summary:"
echo "-------------------------------------------"

# Extract and display key metrics
for file in timing_*.txt; do
    if [ -f "$file" ]; then
        scheme=$(echo $file | sed 's/timing_//' | sed 's/.txt//')
        echo "$scheme:"
        grep "Avg cycles:" "$file" | head -2
        echo ""
    fi
done

echo "=========================================="
echo ""
echo "Full timing details in timing_*.txt files"
echo "Run './summarize_timing.sh' to compare results"
