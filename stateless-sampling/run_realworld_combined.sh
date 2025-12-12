# #!/usr/bin/env bash
# set -euo pipefail

# # Script to run real-world workloads in COMBINED mode
# # Currently supports: memcached

# WORKLOAD=${1:-memcached}
# NUM_BINS=${2:-5}
# DURATION=${3:-1800}  # Duration in seconds (default 60s)

# REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# echo "========================================="
# echo "Running Real-World COMBINED Mode: $WORKLOAD"
# echo "Histogram bins: $NUM_BINS"
# echo "Duration: ${DURATION}s"
# echo "========================================="

# # Create directory structure
# mkdir -p res/real_world_combined

# # Build
# echo "Building..."
# make clean > /dev/null 2>&1
# make > /dev/null 2>&1

# if [[ "$WORKLOAD" == "memcached" ]]; then
#     # Check if memcached is available
#     MEMCACHED_BIN="${REPO_ROOT}/deps/bin/memcached"
#     MEMTIER_BIN="${REPO_ROOT}/deps/bin/memtier_benchmark"
    
#     if [[ ! -f "$MEMCACHED_BIN" ]] || [[ ! -f "$MEMTIER_BIN" ]]; then
#         echo "Error: memcached or memtier_benchmark not found in deps/bin"
#         echo "Please build dependencies first"
#         exit 1
#     fi
    
#     MEMCACHED_HOST="127.0.0.1"
#     MEMCACHED_PORT="11211"
#     THREADS=4
#     CLIENTS=16
    
#     echo ""
#     echo "=== Running COMBINED mode ==="
    
#     # Clean up old results
#     rm -f res/real_world_combined/*.log res/real_world_combined/*.png res/real_world_combined/*.txt
    
#     # Kill any existing memcached
#     pkill -x memcached 2>/dev/null || true
#     sleep 1
    
#     # Start memcached with COMBINED mode
#     env \
#       LD_LIBRARY_PATH="${REPO_ROOT}/deps/lib:${LD_LIBRARY_PATH:-}" \
#       LD_PRELOAD="${REPO_ROOT}/sampler/libsampler.so" \
#       SAMPLER_SCHEME=COMBINED \
#       SAMPLER_POISSON_MEAN_BYTES=1024 \
#       "$MEMCACHED_BIN" -l "$MEMCACHED_HOST" -p "$MEMCACHED_PORT" -m 256 \
#       > res/real_world_combined/trace.log 2> res/real_world_combined/server_stderr.log &
    
#     SERVER_PID=$!
#     sleep 2
    
#     if ! kill -0 $SERVER_PID >/dev/null 2>&1; then
#         echo "Error: memcached failed to start"
#         cat res/real_world_combined/server_stderr.log
#         exit 1
#     fi
    
#     echo "  Running memtier benchmark for ${DURATION}s..."
    
#     # Run memtier_benchmark
#     env LD_LIBRARY_PATH="${REPO_ROOT}/deps/lib:${LD_LIBRARY_PATH:-}" \
#     "$MEMTIER_BIN" \
#         -s "$MEMCACHED_HOST" -p "$MEMCACHED_PORT" \
#         --protocol=memcache_text \
#         --threads="$THREADS" \
#         --clients="$CLIENTS" \
#         --test-time="$DURATION" \
#         --ratio=1:10 \
#         --data-size=128 \
#         --key-maximum=500000 \
#         --hide-histogram \
#         > res/real_world_combined/memtier.log 2>&1
    
#     # Stop memcached gracefully
#     kill -INT $SERVER_PID 2>/dev/null || true
#     sleep 1
#     kill -KILL $SERVER_PID 2>/dev/null || true
#     wait $SERVER_PID 2>/dev/null || true
    
#     echo "  Benchmark complete!"
#     echo "  Trace contains $(wc -l < res/real_world_combined/trace.log) lines"
    
#     # Validate log format
#     echo ""
#     echo "=== Validating log format ==="
#     head -3 res/real_world_combined/trace.log
#     echo "..."
#     tail -3 res/real_world_combined/trace.log
    
#     echo ""
#     echo "  Generating histograms and statistics..."
#     python3 agg_live_heap_combined.py res/real_world_combined/trace.log $NUM_BINS --stats \
#       > res/real_world_combined/analysis_output.txt 2>&1 || echo "  Warning: Analysis had issues (may be too few allocations)"
    
#     echo "  Done. Results in res/real_world_combined/"
    
# else
#     echo "Error: Unknown workload '$WORKLOAD'"
#     echo "Usage: $0 [workload] [num_bins] [duration_seconds]"
#     echo "  workload: memcached (default)"
#     echo "  num_bins: number of histogram time bins (default 5)"
#     echo "  duration: benchmark duration in seconds (default 60)"
#     exit 1
# fi

# echo ""
# echo "========================================="
# echo "Real-world COMBINED benchmark complete!"
# echo ""
# echo "Results in: res/real_world_combined/"
# echo "  - trace.log: Raw malloc/free log (8 columns)"
# echo "  - *_overlay.png: Overlaid histograms"
# echo "  - *_overlay_weighted.png: Weighted estimates"
# echo "  - analysis_output.txt: Statistics"
# echo "  - memtier.log: Benchmark results"
# echo ""
# echo "This shows Poisson vs Stateless Hash on the SAME workload!"
# echo "========================================="

#!/usr/bin/env bash
set -euo pipefail

# Script to run real-world workloads in COMBINED mode
# Currently supports: memcached, curl

WORKLOAD=${1:-memcached}
NUM_BINS=${2:-5}
DURATION=${3:-60}  # Duration in seconds (default 60s, only for memcached)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo "Running Real-World COMBINED Mode: $WORKLOAD"
echo "Histogram bins: $NUM_BINS"
echo "Duration: ${DURATION}s"
echo "========================================="

# Create directory structure
mkdir -p res/real_world_combined

# Build
echo "Building..."
make clean > /dev/null 2>&1
make > /dev/null 2>&1

if [[ "$WORKLOAD" == "memcached" ]]; then
    # Check if memcached is available
    MEMCACHED_BIN="${REPO_ROOT}/deps/bin/memcached"
    MEMTIER_BIN="${REPO_ROOT}/deps/bin/memtier_benchmark"
    
    if [[ ! -f "$MEMCACHED_BIN" ]] || [[ ! -f "$MEMTIER_BIN" ]]; then
        echo "Error: memcached or memtier_benchmark not found in deps/bin"
        echo "Please build dependencies first"
        exit 1
    fi
    
    MEMCACHED_HOST="127.0.0.1"
    MEMCACHED_PORT="11211"
    THREADS=4
    CLIENTS=16
    
    echo ""
    echo "=== Running COMBINED mode ==="
    
    # Clean up old results
    rm -f res/real_world_combined/*.log res/real_world_combined/*.png res/real_world_combined/*.txt
    
    # Kill any existing memcached
    pkill -x memcached 2>/dev/null || true
    sleep 1
    
    # Start memcached with COMBINED mode
    env \
      LD_LIBRARY_PATH="${REPO_ROOT}/deps/lib:${LD_LIBRARY_PATH:-}" \
      LD_PRELOAD="${REPO_ROOT}/sampler/libsampler.so" \
      SAMPLER_SCHEME=COMBINED \
      SAMPLER_POISSON_MEAN_BYTES=1024 \
      "$MEMCACHED_BIN" -l "$MEMCACHED_HOST" -p "$MEMCACHED_PORT" -m 256 \
      > res/real_world_combined/trace.log 2> res/real_world_combined/server_stderr.log &
    
    SERVER_PID=$!
    sleep 2
    
    if ! kill -0 $SERVER_PID >/dev/null 2>&1; then
        echo "Error: memcached failed to start"
        cat res/real_world_combined/server_stderr.log
        exit 1
    fi
    
    echo "  Running memtier benchmark for ${DURATION}s..."
    
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
        > res/real_world_combined/memtier.log 2>&1
    
    # Stop memcached gracefully
    kill -INT $SERVER_PID 2>/dev/null || true
    sleep 1
    kill -KILL $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    
    echo "  Benchmark complete!"
    echo "  Trace contains $(wc -l < res/real_world_combined/trace.log) lines"
    
    # Validate log format
    echo ""
    echo "=== Validating log format ==="
    head -3 res/real_world_combined/trace.log
    echo "..."
    tail -3 res/real_world_combined/trace.log
    
    echo ""
    echo "  Generating histograms and statistics..."
    python3 agg_live_heap_combined.py res/real_world_combined/trace.log $NUM_BINS --stats \
      > res/real_world_combined/analysis_output.txt 2>&1 || echo "  Warning: Analysis had issues (may be too few allocations)"
    
    echo "  Done. Results in res/real_world_combined/"
    
elif [[ "$WORKLOAD" == "curl" ]]; then
    # Curl compilation benchmark
    CURL_VERSION="8.5.0"
    CURL_URL="https://curl.se/download/curl-${CURL_VERSION}.tar.gz"
    CURL_DIR="${REPO_ROOT}/deps/src/curl-${CURL_VERSION}"
    
    echo ""
    echo "=== Running COMBINED mode (curl compilation) ==="
    
    # Clean up old results
    rm -f res/real_world_combined/*.log res/real_world_combined/*.png res/real_world_combined/*.txt
    
    # Download and extract curl if needed
    if [[ ! -d "$CURL_DIR" ]]; then
        echo "  Downloading curl source..."
        mkdir -p "${REPO_ROOT}/deps/src"
        cd "${REPO_ROOT}/deps/src"
        curl -sL "$CURL_URL" -o "curl-${CURL_VERSION}.tar.gz"
        tar xzf "curl-${CURL_VERSION}.tar.gz"
    fi
    
    cd "$CURL_DIR"
    
    # Clean previous build
    echo "  Cleaning previous build..."
    make clean > /dev/null 2>&1 || true
    make distclean > /dev/null 2>&1 || true
    
    # Run configure (not profiled, just setup)
    echo "  Running configure..."
    ./configure --prefix="${REPO_ROOT}/deps" --disable-shared --without-ssl > /dev/null 2>&1
    
    echo "  Compiling curl with profiling..."
    echo "  This will take a few minutes..."
    echo "  (Compilation output -> compile.log, Profiler output -> trace.log)"
    
    # Run make with LD_PRELOAD to capture all allocations
    # stdout (profiler traces) -> trace.log
    # stderr (compilation messages) -> compile.log for debugging
    SAMPLER_ENV="LD_PRELOAD=${REPO_ROOT}/sampler/libsampler.so SAMPLER_SCHEME=COMBINED SAMPLER_POISSON_MEAN_BYTES=1024"
    
    make -j4 \
      CC="env ${SAMPLER_ENV} gcc" \
      CXX="env ${SAMPLER_ENV} g++" \
      > "${REPO_ROOT}/res/real_world_combined/trace.log" \
      2> "${REPO_ROOT}/res/real_world_combined/compile.log"
    
    cd "$REPO_ROOT"
    
    echo "  Compilation complete!"
    echo "  Trace contains $(wc -l < res/real_world_combined/trace.log) lines"
    echo "  Compilation log: res/real_world_combined/compile.log"
    
    # Validate log format
    echo ""
    echo "=== Validating log format ==="
    head -3 res/real_world_combined/trace.log
    echo "..."
    tail -3 res/real_world_combined/trace.log
    
    echo ""
    echo "  Generating histograms and statistics..."
    python3 agg_live_heap_combined.py res/real_world_combined/trace.log $NUM_BINS --stats \
      > res/real_world_combined/analysis_output.txt 2>&1
    
    echo "  Done. Results in res/real_world_combined/"
    
else
    echo "Error: Unknown workload '$WORKLOAD'"
    echo "Usage: $0 [workload] [num_bins] [duration_seconds]"
    echo "  workload: memcached (default) or curl"
    echo "  num_bins: number of histogram time bins (default 5)"
    echo "  duration: benchmark duration in seconds (default 60, memcached only)"
    exit 1
fi

echo ""
echo "========================================="
echo "Real-world COMBINED benchmark complete!"
echo ""
if [[ "$WORKLOAD" == "memcached" ]]; then
    echo "Workload: Memcached (${DURATION}s benchmark)"
elif [[ "$WORKLOAD" == "curl" ]]; then
    echo "Workload: Curl compilation"
fi
echo ""
echo "Results in: res/real_world_combined/"
echo "  - trace.log: Raw malloc/free log (8 columns)"
echo "  - trace_live_heap_over_time.png: Live heap bar chart"
echo "  - trace_size_freq_hash_*.png: Size frequency charts"
echo "  - analysis_output.txt: Statistics"
echo ""
echo "This shows Poisson vs Stateless Hash on the SAME workload!"
echo "========================================="
