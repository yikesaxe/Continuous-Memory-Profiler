#!/bin/bash
# High Address Reuse Workload
# Allocates into a small pool of hot slots, churns repeatedly
# Tests: Does stateless hash sampling go blind when addresses repeat?

set -e

# Configuration defaults
HOT_SLOTS=${WORKLOAD_SLOTS:-100}
ITERATIONS=${WORKLOAD_ITERATIONS:-100000}
MIN_SIZE=${WORKLOAD_MIN_SIZE:-16}
MAX_SIZE=${WORKLOAD_MAX_SIZE:-256}
BENCH_BINARY=${BENCH_BINARY:-"../../../stateless-sampling/bench/bench_alloc_patterns"}
SAMPLER_LIB=${SAMPLER_LIB:-"../../../stateless-sampling/sampler/libsampler.so"}

# Sampler configuration (must be set by caller)
: ${SAMPLER_SCHEME:?SAMPLER_SCHEME must be set (e.g., STATELESS_HASH, POISSON_HEADER)}
: ${SAMPLER_STATS_FILE:?SAMPLER_STATS_FILE must be set}

# Optional Poisson mean
SAMPLER_POISSON_MEAN_BYTES=${SAMPLER_POISSON_MEAN_BYTES:-4096}

echo "=== Running High Address Reuse Workload ==="
echo "Configuration:"
echo "  Hot slots:            $HOT_SLOTS"
echo "  Iterations:           $ITERATIONS"
echo "  Size range:           $MIN_SIZE - $MAX_SIZE bytes"
echo "  Sampler scheme:       $SAMPLER_SCHEME"
echo "  Sampler lib:          $SAMPLER_LIB"
echo "  Stats file:           $SAMPLER_STATS_FILE"
echo "  Poisson mean:         $SAMPLER_POISSON_MEAN_BYTES bytes"
echo ""

# Check if bench binary exists
if [[ ! -f "$BENCH_BINARY" ]]; then
    echo "ERROR: Benchmark binary not found at: $BENCH_BINARY"
    echo "Please run 'make' in stateless-sampling/ directory first"
    exit 1
fi

# Check if sampler library exists
if [[ ! -f "$SAMPLER_LIB" ]]; then
    echo "ERROR: Sampler library not found at: $SAMPLER_LIB"
    echo "Please run 'make' in stateless-sampling/ directory first"
    exit 1
fi

# Run workload
# Mode 4 = High reuse
SAMPLER_SCHEME="$SAMPLER_SCHEME" \
SAMPLER_STATS_FILE="$SAMPLER_STATS_FILE" \
SAMPLER_POISSON_MEAN_BYTES="$SAMPLER_POISSON_MEAN_BYTES" \
LD_PRELOAD="$SAMPLER_LIB" \
"$BENCH_BINARY" 4 "$HOT_SLOTS" "$ITERATIONS" "$MIN_SIZE" "$MAX_SIZE"

echo ""
echo "✓ High reuse workload complete"
echo "  Stats written to: $SAMPLER_STATS_FILE"
