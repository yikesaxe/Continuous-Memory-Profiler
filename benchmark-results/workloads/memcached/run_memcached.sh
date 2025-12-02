#!/bin/bash
# Memcached Workload
# Runs memcached under profiling and benchmarks it with memtier
# Tests: Overhead on a production key-value store

set -e

# Configuration
MEMCACHED_PORT=${MEMCACHED_PORT:-11211}
MEMCACHED_THREADS=${MEMCACHED_THREADS:-4}
MEMTIER_CLIENTS=${MEMTIER_CLIENTS:-4}
MEMTIER_THREADS=${MEMTIER_THREADS:-4}
MEMTIER_REQUESTS=${MEMTIER_REQUESTS:-50000}
MEMTIER_PIPELINE=${MEMTIER_PIPELINE:-16}
SAMPLER_LIB=${SAMPLER_LIB:-"../../stateless-sampling/sampler/libsampler.so"}

# Sampler configuration (must be set by caller)
: ${SAMPLER_SCHEME:?SAMPLER_SCHEME must be set (e.g., STATELESS_HASH, POISSON_HEADER)}
: ${SAMPLER_STATS_FILE:?SAMPLER_STATS_FILE must be set}

# Optional Poisson mean
SAMPLER_POISSON_MEAN_BYTES=${SAMPLER_POISSON_MEAN_BYTES:-4096}

echo "=== Running Memcached Workload ==="
echo "Configuration:"
echo "  Port:                 $MEMCACHED_PORT"
echo "  Memcached threads:    $MEMCACHED_THREADS"
echo "  Memtier clients:      $MEMTIER_CLIENTS"
echo "  Memtier threads:      $MEMTIER_THREADS"
echo "  Requests per client:  $MEMTIER_REQUESTS"
echo "  Pipeline:             $MEMTIER_PIPELINE"
echo "  Sampler scheme:       $SAMPLER_SCHEME"
echo "  Sampler lib:          $SAMPLER_LIB"
echo "  Stats file:           $SAMPLER_STATS_FILE"
echo "  Poisson mean:         $SAMPLER_POISSON_MEAN_BYTES bytes"
echo ""

# Check if sampler library exists
if [[ ! -f "$SAMPLER_LIB" ]]; then
    echo "ERROR: Sampler library not found at: $SAMPLER_LIB"
    echo "Please run 'make' in stateless-sampling/ directory first"
    exit 1
fi

# Check if memcached is installed
if ! command -v memcached &> /dev/null; then
    echo "ERROR: memcached not found. Install with: sudo apt-get install memcached"
    exit 1
fi

# Check if memtier_benchmark is installed
if ! command -v memtier_benchmark &> /dev/null; then
    echo "ERROR: memtier_benchmark not found. Install with: sudo apt-get install memtier-benchmark"
    exit 1
fi

# Kill any existing memcached on this port
pkill -f "memcached.*$MEMCACHED_PORT" 2>/dev/null || true
sleep 1

# Start memcached under profiling
echo "Starting memcached with profiling..."
SAMPLER_SCHEME="$SAMPLER_SCHEME" \
SAMPLER_STATS_FILE="$SAMPLER_STATS_FILE" \
SAMPLER_POISSON_MEAN_BYTES="$SAMPLER_POISSON_MEAN_BYTES" \
LD_PRELOAD="$SAMPLER_LIB" \
memcached -p "$MEMCACHED_PORT" -t "$MEMCACHED_THREADS" -m 256 &

MEMCACHED_PID=$!
echo "  Memcached PID: $MEMCACHED_PID"

# Wait for memcached to start
sleep 2

# Check if memcached started successfully
if ! kill -0 $MEMCACHED_PID 2>/dev/null; then
    echo "ERROR: memcached failed to start"
    exit 1
fi

# Run memtier benchmark
echo "Running memtier_benchmark..."
memtier_benchmark \
    -s localhost \
    -p "$MEMCACHED_PORT" \
    --protocol=memcache_text \
    --clients="$MEMTIER_CLIENTS" \
    --threads="$MEMTIER_THREADS" \
    --requests="$MEMTIER_REQUESTS" \
    --pipeline="$MEMTIER_PIPELINE" \
    --data-size=128 \
    --ratio=1:1 \
    --key-pattern=R:R

# Stop memcached
echo "Stopping memcached..."
kill $MEMCACHED_PID 2>/dev/null || true
wait $MEMCACHED_PID 2>/dev/null || true

echo ""
echo "✓ Memcached workload complete"
echo "  Stats written to: $SAMPLER_STATS_FILE"
