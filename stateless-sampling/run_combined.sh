#!/usr/bin/env bash
set -euo pipefail

# Script to run benchmarks in COMBINED mode (both Poisson and Hash evaluated simultaneously)
# Usage: ./run_combined.sh [workload] [num_bins]
#   workload 1: Monotonic heap with leaks (default)
#   workload 2: Steady state pool with leaks

WORKLOAD=${1:-1}         # Default: workload 1 (monotonic)
NUM_BINS=${2:-10}        # Default: 10 time bins

# Workload-specific parameters
if [ "$WORKLOAD" = "1" ]; then
    WORKLOAD_NAME="Monotonic Heap with Leaks"
    NUM_ALLOCS=100000
    MIN_SIZE=16
    MAX_SIZE=4096
    BENCH_ARGS="$WORKLOAD $NUM_ALLOCS $MIN_SIZE $MAX_SIZE"
elif [ "$WORKLOAD" = "2" ]; then
    WORKLOAD_NAME="Steady State Pool with Leaks"
    ITERATIONS=1000
    POOL_SIZE=500
    MIN_SIZE=16
    MAX_SIZE=4096
    ALLOC_PROB=60
    BENCH_ARGS="$WORKLOAD $ITERATIONS $POOL_SIZE $MIN_SIZE $MAX_SIZE $ALLOC_PROB"
elif [ "$WORKLOAD" = "3" ]; then
    WORKLOAD_NAME="Repeat Leaks"
    BENCH_ARGS="$WORKLOAD"
else
    echo "Error: Unknown workload $WORKLOAD"
    echo "Usage: $0 [workload] [num_bins]"
    echo "  workload: 1 (monotonic, default) or 2 (steady state)"
    echo "  num_bins: number of time bins (default: 10)"
    exit 1
fi

echo "========================================="
echo "Running COMBINED Sampling Analysis"
echo "Workload $WORKLOAD: $WORKLOAD_NAME"
echo "Time bins: $NUM_BINS"
echo "========================================="

# Create directory structure
mkdir -p res/combined

# Clean up old results
echo "Cleaning up old results..."
rm -f res/combined/*.log res/combined/*.png res/combined/*.txt

# Build
echo "Building..."
make clean > /dev/null 2>&1
make > /dev/null 2>&1

# Run in COMBINED mode
echo ""
echo "=== Running COMBINED mode (Poisson + Stateless Hash) ==="
SAMPLER_SCHEME=COMBINED \
  SAMPLER_POISSON_MEAN_BYTES=1024 \
  LD_PRELOAD=./sampler/libsampler.so \
  ./bench/bench_alloc_patterns $BENCH_ARGS \
  > res/combined/trace.log 2>&1

echo "  Benchmark complete!"
echo "  Trace contains $(wc -l < res/combined/trace.log) lines"

# Validate log format
echo ""
echo "=== Validating log format ==="
head -3 res/combined/trace.log
echo "..."
tail -3 res/combined/trace.log

# Generate overlaid histograms
echo ""
echo "  Generating overlaid histograms..."
python3 agg_live_heap_combined.py res/combined/trace.log $NUM_BINS --stats \
  > res/combined/analysis_output.txt 2>&1

echo "  Done!"

echo ""
echo "========================================="
echo "COMBINED benchmark complete!"
echo ""
echo "Workload: $WORKLOAD_NAME"
echo "Results in: res/combined/"
echo "  - trace.log: Raw malloc/free log (8 columns)"
echo "  - trace_live_heap_over_time.png: Bar chart of heap size over time"
echo "  - analysis_output.txt: Text summary & statistics"
echo ""
echo "Log format:"
echo "  MALLOC: op, ts, addr, size, pois_tracked, pois_size, hash_tracked, hash_size"
echo "  FREE: op, ts, addr, -1, pois_tracked, -1, hash_tracked, -1"
echo ""
echo "To run workload 2: ./run_combined.sh 2"
echo "========================================="
