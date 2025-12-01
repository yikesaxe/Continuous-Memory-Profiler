#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULT_DIR="${REPO_ROOT}/results_real_world"
mkdir -p "$RESULT_DIR"

# Paths to local binaries
MEMCACHED_BIN="${REPO_ROOT}/deps/bin/memcached"
MEMTIER_BIN="${REPO_ROOT}/deps/bin/memtier_benchmark"

if [[ ! -f "${REPO_ROOT}/sampler/libsampler.so" ]]; then
    echo "Error: ${REPO_ROOT}/sampler/libsampler.so not found."
    echo "Please run 'make' at the repo root first."
    exit 1
fi

if [[ ! -f "$MEMCACHED_BIN" ]] || [[ ! -f "$MEMTIER_BIN" ]]; then
    echo "Error: Local memcached or memtier_benchmark not found in deps/bin."
    exit 1
fi

MEMCACHED_HOST="127.0.0.1"
MEMCACHED_PORT="11211"
DURATION=10
THREADS=4
CLIENTS=16

echo "Running memcached benchmarks..."

run_scheme() {
    local SCHEME="$1"
    local POISSON_MEAN="$2"

    echo "  - Running Scheme: $SCHEME"
    
    # Clean up previous run if any
    if pgrep -x memcached > /dev/null; then pkill -x memcached; sleep 1; fi

    local MEAN_ENV=""
    if [[ -n "$POISSON_MEAN" ]]; then
        MEAN_ENV="SAMPLER_POISSON_MEAN_BYTES=$POISSON_MEAN"
    fi

    # Start memcached with LD_PRELOAD
    # Need to point LD_LIBRARY_PATH to local libevent if needed, but we linked statically or rpath might handle it.
    # We installed libs to deps/lib.
    env \
      LD_LIBRARY_PATH="${REPO_ROOT}/deps/lib:${LD_LIBRARY_PATH:-}" \
      LD_PRELOAD="${REPO_ROOT}/sampler/libsampler.so" \
      SAMPLER_SCHEME="$SCHEME" \
      SAMPLER_STATS_FILE="${RESULT_DIR}/memcached_${SCHEME}.json" \
      $MEAN_ENV \
      "$MEMCACHED_BIN" -l "$MEMCACHED_HOST" -p "$MEMCACHED_PORT" -m 256 -vv > "${RESULT_DIR}/memcached_${SCHEME}_server.log" 2>&1 &
    
    local SERVER_PID=$!
    sleep 2

    if ! kill -0 $SERVER_PID >/dev/null 2>&1; then
        echo "Error: memcached failed to start or crashed."
        cat "${RESULT_DIR}/memcached_${SCHEME}_server.log"
        exit 1
    fi

    # Run memtier_benchmark
    env LD_LIBRARY_PATH="${REPO_ROOT}/deps/lib:${LD_LIBRARY_PATH:-}" \
    "$MEMTIER_BIN" \
        -s "$MEMCACHED_HOST" -p "$MEMCACHED_PORT" \
        --protocol=memcache_text \
        --threads="$THREADS" \
        --clients="$CLIENTS" \
        --test-time="$DURATION" \
        --ratio=1:10 \
        --data-size=128 \
        --key-maximum=500000 \
        --hide-histogram \
        > "${RESULT_DIR}/memcached_${SCHEME}_memtier.log" 2>&1

    # Stop memcached
    kill $SERVER_PID
    wait $SERVER_PID || true

    if [[ ! -f "${RESULT_DIR}/memcached_${SCHEME}.json" ]]; then
        echo "Warning: No stats file produced for $SCHEME"
    else
        echo "    Stats written to ${RESULT_DIR}/memcached_${SCHEME}.json"
    fi
}

run_scheme "STATELESS_HASH" ""
run_scheme "POISSON_HEADER" "4096"
run_scheme "PAGE_HASH" ""
run_scheme "HYBRID" "65536"

echo "Memcached benchmarks completed."
