#!/bin/bash
# Unified Workload Driver
# Dispatches to specific workload scripts with standardized interface
#
# Usage:
#   ./run_workload.sh <workload> <sampler_scheme> <stats_file> [extra_env_vars...]
#
# Example:
#   ./run_workload.sh monotonic STATELESS_HASH /tmp/stats.json
#   ./run_workload.sh high-reuse POISSON_HEADER /tmp/stats.json SAMPLER_POISSON_MEAN_BYTES=65536
#   ./run_workload.sh curl HYBRID /tmp/curl_stats.json

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
if [[ $# -lt 3 ]]; then
    cat <<EOF
Usage: $0 <workload> <sampler_scheme> <stats_file> [extra_env_vars...]

Workloads:
  monotonic      - Monotonic heap (100k allocs, 5% leak)
  high-reuse     - High address reuse (100 slots, 100k churn)
  curl           - Curl compilation workload
  memcached      - Memcached + memtier benchmark
  nginx          - Nginx + wrk benchmark

Sampler Schemes:
  STATELESS_HASH           - XOR-shift hash on address
  POISSON_HEADER          - Poisson sampling based on bytes
  PAGE_HASH               - Hash on page number
  HYBRID                  - Small allocs use Poisson, large use hash

Stats File:
  Path where JSON statistics will be written

Extra Environment Variables (optional):
  SAMPLER_POISSON_MEAN_BYTES=N     - Mean bytes between samples (default: 4096)
  SAMPLER_LIB=path                 - Path to libsampler.so
  WORKLOAD_*=value                 - Workload-specific parameters

Examples:
  # Run monotonic with stateless hash
  $0 monotonic STATELESS_HASH /tmp/mono_hash.json

  # Run high-reuse with Poisson (64KB mean)
  $0 high-reuse POISSON_HEADER /tmp/reuse_poisson.json SAMPLER_POISSON_MEAN_BYTES=65536

  # Run curl with hybrid sampling
  $0 curl HYBRID /tmp/curl_hybrid.json

  # Run memcached with custom port
  $0 memcached STATELESS_HASH /tmp/memcached.json MEMCACHED_PORT=11212
EOF
    exit 1
fi

WORKLOAD="$1"
SAMPLER_SCHEME="$2"
STATS_FILE="$3"
shift 3

# Parse extra environment variables
for arg in "$@"; do
    if [[ "$arg" =~ ^([A-Z_]+)=(.*)$ ]]; then
        export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
        echo "Setting ${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
    else
        echo "WARNING: Ignoring invalid env var format: $arg"
    fi
done

# Export required variables
export SAMPLER_SCHEME
export SAMPLER_STATS_FILE="$STATS_FILE"

# Ensure stats file uses absolute path
if [[ ! "$SAMPLER_STATS_FILE" = /* ]]; then
    SAMPLER_STATS_FILE="$(pwd)/$SAMPLER_STATS_FILE"
    export SAMPLER_STATS_FILE
fi

echo "=========================================="
echo "Workload Driver"
echo "=========================================="
echo "Workload:       $WORKLOAD"
echo "Scheme:         $SAMPLER_SCHEME"
echo "Stats file:     $SAMPLER_STATS_FILE"
echo "=========================================="
echo ""

# Dispatch to appropriate workload
case "$WORKLOAD" in
    monotonic)
        cd "$SCRIPT_DIR/synthetic"
        ./run_monotonic.sh
        ;;
    
    high-reuse)
        cd "$SCRIPT_DIR/synthetic"
        ./run_high_reuse.sh
        ;;
    
    curl)
        cd "$SCRIPT_DIR/curl"
        ./run_curl.sh
        ;;
    
    memcached)
        cd "$SCRIPT_DIR/memcached"
        ./run_memcached.sh
        ;;
    
    nginx)
        cd "$SCRIPT_DIR/nginx"
        ./run_nginx.sh
        ;;
    
    *)
        echo "ERROR: Unknown workload: $WORKLOAD"
        echo "Available workloads: monotonic, high-reuse, curl, memcached, nginx"
        exit 1
        ;;
esac

echo ""
echo "=========================================="
echo "✓ Workload complete: $WORKLOAD"
echo "  Stats file: $SAMPLER_STATS_FILE"
echo "=========================================="
