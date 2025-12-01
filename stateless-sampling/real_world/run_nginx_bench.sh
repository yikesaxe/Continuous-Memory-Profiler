#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULT_DIR="${REPO_ROOT}/results_real_world"
mkdir -p "$RESULT_DIR"

# Paths to local binaries
NGINX_BIN="${REPO_ROOT}/deps/nginx/sbin/nginx"
WRK_BIN="${REPO_ROOT}/deps/bin/wrk"

if [[ ! -f "${REPO_ROOT}/sampler/libsampler.so" ]]; then
    echo "Error: ${REPO_ROOT}/sampler/libsampler.so not found."
    echo "Please run 'make' at the repo root first."
    exit 1
fi

if [[ ! -f "$NGINX_BIN" ]] || [[ ! -f "$WRK_BIN" ]]; then
    echo "Error: Local nginx or wrk not found."
    exit 1
fi

# Setup nginx environment
NGINX_PREFIX="${REPO_ROOT}/real_world/nginx_prefix"
NGINX_CONF="${REPO_ROOT}/real_world/nginx_profiled.conf"
NGINX_HTML="${REPO_ROOT}/real_world/nginx_root"

mkdir -p "$NGINX_PREFIX/logs"
mkdir -p "$NGINX_HTML"
echo "<html><body><h1>Stateless Sampling Benchmark</h1></body></html>" > "${NGINX_HTML}/index.html"

# Create minimal nginx config
cat > "$NGINX_CONF" <<EOF
worker_processes 1;
error_log ${NGINX_PREFIX}/logs/error.log;
pid ${NGINX_PREFIX}/logs/nginx.pid;
events { worker_connections 1024; }
http {
    access_log off;
    server {
        listen 127.0.0.1:8080;
        root ${NGINX_HTML};
    }
}
EOF

DURATION="10s"

echo "Running nginx benchmarks..."

run_scheme() {
    local SCHEME="$1"
    local POISSON_MEAN="$2"

    echo "  - Running Scheme: $SCHEME"

    # Stop any existing nginx
    if pgrep -f "nginx_profiled.conf" > /dev/null; then
         "$NGINX_BIN" -s quit -p "$NGINX_PREFIX" -c "$NGINX_CONF" || pkill -f "nginx_profiled.conf"
         sleep 1
    fi

    local MEAN_ENV=""
    if [[ -n "$POISSON_MEAN" ]]; then
        MEAN_ENV="SAMPLER_POISSON_MEAN_BYTES=$POISSON_MEAN"
    fi

    # Start nginx with LD_PRELOAD
    env \
      LD_PRELOAD="${REPO_ROOT}/sampler/libsampler.so" \
      SAMPLER_SCHEME="$SCHEME" \
      SAMPLER_STATS_FILE="${RESULT_DIR}/nginx_${SCHEME}.json" \
      $MEAN_ENV \
      "$NGINX_BIN" -p "$NGINX_PREFIX" -c "$NGINX_CONF" &
    
    sleep 2
    if ! pgrep -f "nginx_profiled.conf" > /dev/null; then
        echo "Error: nginx failed to start."
        cat "${NGINX_PREFIX}/logs/error.log"
        exit 1
    fi

    # Run wrk
    "$WRK_BIN" -t4 -c64 -d"$DURATION" "http://127.0.0.1:8080/" > "${RESULT_DIR}/nginx_${SCHEME}_wrk.log" 2>&1

    # Stop nginx
    "$NGINX_BIN" -s quit -p "$NGINX_PREFIX" -c "$NGINX_CONF"
    sleep 1

    if [[ ! -f "${RESULT_DIR}/nginx_${SCHEME}.json" ]]; then
        if ls "${RESULT_DIR}/nginx_${SCHEME}.json"* 1> /dev/null 2>&1; then
             echo "    Stats written (multiple files likely)."
        else
             echo "Warning: No stats file produced for $SCHEME"
        fi
    else
        echo "    Stats written to ${RESULT_DIR}/nginx_${SCHEME}.json"
    fi
}

run_scheme "STATELESS_HASH" ""
run_scheme "POISSON_HEADER" "4096"
run_scheme "PAGE_HASH" ""
run_scheme "HYBRID" "65536"

echo "Nginx benchmarks completed."
