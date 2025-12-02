#!/bin/bash
# Nginx Workload
# Runs nginx under profiling and benchmarks it with wrk
# Tests: Overhead on a production web server

set -e

# Configuration
NGINX_PORT=${NGINX_PORT:-8080}
NGINX_WORKERS=${NGINX_WORKERS:-2}
WRK_THREADS=${WRK_THREADS:-4}
WRK_CONNECTIONS=${WRK_CONNECTIONS:-100}
WRK_DURATION=${WRK_DURATION:-30s}
SAMPLER_LIB=${SAMPLER_LIB:-"../../stateless-sampling/sampler/libsampler.so"}
NGINX_CONF=${NGINX_CONF:-"../../stateless-sampling/real_world/nginx_profiled.conf"}

# Sampler configuration (must be set by caller)
: ${SAMPLER_SCHEME:?SAMPLER_SCHEME must be set (e.g., STATELESS_HASH, POISSON_HEADER)}
: ${SAMPLER_STATS_FILE:?SAMPLER_STATS_FILE must be set}

# Optional Poisson mean
SAMPLER_POISSON_MEAN_BYTES=${SAMPLER_POISSON_MEAN_BYTES:-4096}

echo "=== Running Nginx Workload ==="
echo "Configuration:"
echo "  Port:                 $NGINX_PORT"
echo "  Workers:              $NGINX_WORKERS"
echo "  WRK threads:          $WRK_THREADS"
echo "  WRK connections:      $WRK_CONNECTIONS"
echo "  WRK duration:         $WRK_DURATION"
echo "  Nginx config:         $NGINX_CONF"
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

# Check if nginx is installed
if ! command -v nginx &> /dev/null; then
    echo "ERROR: nginx not found. Install with: sudo apt-get install nginx"
    exit 1
fi

# Check if wrk is installed
if ! command -v wrk &> /dev/null; then
    echo "ERROR: wrk not found. Install from source:"
    echo "  git clone https://github.com/wg/wrk.git && cd wrk && make && sudo cp wrk /usr/local/bin/"
    exit 1
fi

# Check if nginx config exists
if [[ ! -f "$NGINX_CONF" ]]; then
    echo "ERROR: Nginx config not found at: $NGINX_CONF"
    exit 1
fi

# Kill any existing nginx
pkill -f "nginx.*master" 2>/dev/null || true
sleep 1

# Start nginx under profiling
echo "Starting nginx with profiling..."
SAMPLER_SCHEME="$SAMPLER_SCHEME" \
SAMPLER_STATS_FILE="$SAMPLER_STATS_FILE" \
SAMPLER_POISSON_MEAN_BYTES="$SAMPLER_POISSON_MEAN_BYTES" \
LD_PRELOAD="$SAMPLER_LIB" \
nginx -c "$(realpath $NGINX_CONF)"

# Wait for nginx to start
sleep 2

# Check if nginx started successfully
if ! pgrep -f "nginx.*master" > /dev/null; then
    echo "ERROR: nginx failed to start"
    exit 1
fi

# Run wrk benchmark
echo "Running wrk benchmark..."
wrk \
    -t"$WRK_THREADS" \
    -c"$WRK_CONNECTIONS" \
    -d"$WRK_DURATION" \
    "http://localhost:$NGINX_PORT/"

# Stop nginx
echo "Stopping nginx..."
pkill -f "nginx.*master" 2>/dev/null || true
sleep 1

echo ""
echo "✓ Nginx workload complete"
echo "  Stats written to: $SAMPLER_STATS_FILE"
