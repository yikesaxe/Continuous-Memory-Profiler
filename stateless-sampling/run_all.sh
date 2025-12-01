#!/usr/bin/env bash
set -euo pipefail

# Configuration
SYNTH_RUNS=10
REAL_RUNS=5

# Build everything
echo "Building project..."
make clean
make

# Directory for results
RESULT_DIR="results_real_world"
mkdir -p "$RESULT_DIR"

echo "========================================="
echo "Running Multi-Run Experiments"
echo "Synthetic: $SYNTH_RUNS runs per scheme"
echo "Real-world: $REAL_RUNS runs per scheme"
echo "========================================="

# 1. Synthetic Benchmarks - Monotonic
echo ""
echo "=== Synthetic: Monotonic Workload ==="
for scheme in STATELESS_HASH POISSON_HEADER PAGE_HASH HYBRID; do
    echo "  Scheme: $scheme"
    
    # Set Poisson mean based on scheme
    if [[ "$scheme" == "POISSON_HEADER" ]]; then
        MEAN="524288"
    elif [[ "$scheme" == "HYBRID" ]]; then
        MEAN="65536"
    else
        MEAN=""
    fi
    
    for i in $(seq 1 $SYNTH_RUNS); do
        echo -n "    Run $i/$SYNTH_RUNS..."
        
        MEAN_ENV=""
        if [[ -n "$MEAN" ]]; then
            MEAN_ENV="SAMPLER_POISSON_MEAN_BYTES=$MEAN"
        fi
        
        env \
          SAMPLER_SCHEME="$scheme" \
          SAMPLER_STATS_FILE="/tmp/test_mono_${scheme}_run${i}.json" \
          $MEAN_ENV \
          LD_PRELOAD=./sampler/libsampler.so \
          ./bench/bench_alloc_patterns 1 100000 16 4096 > /dev/null 2>&1
        
        echo " done"
    done
done

# 2. Synthetic Benchmarks - High Reuse
echo ""
echo "=== Synthetic: High Reuse Workload ==="
for scheme in STATELESS_HASH POISSON_HEADER PAGE_HASH HYBRID; do
    echo "  Scheme: $scheme"
    
    # Set Poisson mean based on scheme
    if [[ "$scheme" == "POISSON_HEADER" ]] || [[ "$scheme" == "HYBRID" ]]; then
        MEAN="65536"
    else
        MEAN=""
    fi
    
    for i in $(seq 1 $SYNTH_RUNS); do
        echo -n "    Run $i/$SYNTH_RUNS..."
        
        MEAN_ENV=""
        if [[ -n "$MEAN" ]]; then
            MEAN_ENV="SAMPLER_POISSON_MEAN_BYTES=$MEAN"
        fi
        
        env \
          SAMPLER_SCHEME="$scheme" \
          SAMPLER_STATS_FILE="/tmp/test_reuse_${scheme}_run${i}.json" \
          $MEAN_ENV \
          LD_PRELOAD=./sampler/libsampler.so \
          ./bench/bench_alloc_patterns 4 100 100000 16 256 > /dev/null 2>&1
        
        echo " done"
    done
done

# 3. Real Workload - Curl Compilation
echo ""
echo "=== Real-World: Curl Compilation ==="
for scheme in STATELESS_HASH POISSON_HEADER PAGE_HASH HYBRID; do
    echo "  Scheme: $scheme"
    
    # Set Poisson mean based on scheme
    if [[ "$scheme" == "POISSON_HEADER" ]] || [[ "$scheme" == "HYBRID" ]]; then
        MEAN="4096"
    else
        MEAN=""
    fi
    
    for i in $(seq 1 $REAL_RUNS); do
        echo -n "    Run $i/$REAL_RUNS..."
        
        make -C curl clean > /dev/null 2>&1
        
        MEAN_ENV=""
        if [[ -n "$MEAN" ]]; then
            MEAN_ENV="SAMPLER_POISSON_MEAN_BYTES=$MEAN"
        fi
        
        env \
          SAMPLER_SCHEME="$scheme" \
          SAMPLER_STATS_FILE="/tmp/curl_${scheme}_run${i}.json" \
          $MEAN_ENV \
          LD_PRELOAD=./sampler/libsampler.so \
          make -C curl -j$(nproc) > "$RESULT_DIR/curl_${scheme}_run${i}.log" 2>&1
        
        echo " done"
    done
done

# 4. Real Workload - Memcached
echo ""
echo "=== Real-World: Memcached + Memtier ==="

MEMCACHED_BIN="./deps/bin/memcached"
MEMTIER_BIN="./deps/bin/memtier_benchmark"
MEMCACHED_HOST="127.0.0.1"
MEMCACHED_PORT="11211"
DURATION=10
THREADS=4
CLIENTS=16

for scheme in STATELESS_HASH POISSON_HEADER PAGE_HASH HYBRID; do
    echo "  Scheme: $scheme"
    
    # Set Poisson mean based on scheme
    if [[ "$scheme" == "POISSON_HEADER" ]] || [[ "$scheme" == "HYBRID" ]]; then
        MEAN="4096"
    else
        MEAN=""
    fi
    
    for i in $(seq 1 $REAL_RUNS); do
        echo -n "    Run $i/$REAL_RUNS..."
        
        # Clean up any existing memcached
        pkill -x memcached 2>/dev/null || true
        sleep 1
        
        MEAN_ENV=""
        if [[ -n "$MEAN" ]]; then
            MEAN_ENV="SAMPLER_POISSON_MEAN_BYTES=$MEAN"
        fi
        
        # Start memcached with LD_PRELOAD
        env \
          LD_LIBRARY_PATH="./deps/lib:${LD_LIBRARY_PATH:-}" \
          LD_PRELOAD="./sampler/libsampler.so" \
          SAMPLER_SCHEME="$scheme" \
          SAMPLER_STATS_FILE="/tmp/memcached_${scheme}_run${i}.json" \
          $MEAN_ENV \
          "$MEMCACHED_BIN" -l "$MEMCACHED_HOST" -p "$MEMCACHED_PORT" -m 256 > "$RESULT_DIR/memcached_${scheme}_run${i}_server.log" 2>&1 &
        
        SERVER_PID=$!
        sleep 2
        
        # Run memtier_benchmark
        env LD_LIBRARY_PATH="./deps/lib:${LD_LIBRARY_PATH:-}" \
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
            > "$RESULT_DIR/memcached_${scheme}_run${i}.log" 2>&1
        
        # Stop memcached
        kill $SERVER_PID 2>/dev/null || true
        wait $SERVER_PID 2>/dev/null || true
        
        echo " done"
    done
done

# 5. Real Workload - Nginx
echo ""
echo "=== Real-World: Nginx + Wrk ==="

NGINX_BIN="./deps/nginx/sbin/nginx"
WRK_BIN="./deps/bin/wrk"
NGINX_PREFIX="./real_world/nginx_prefix"
NGINX_CONF="./real_world/nginx_profiled.conf"
NGINX_HTML="./real_world/nginx_root"

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

DURATION_WRK="10s"

for scheme in STATELESS_HASH POISSON_HEADER PAGE_HASH HYBRID; do
    echo "  Scheme: $scheme"
    
    # Set Poisson mean based on scheme
    if [[ "$scheme" == "POISSON_HEADER" ]] || [[ "$scheme" == "HYBRID" ]]; then
        MEAN="4096"
    else
        MEAN=""
    fi
    
    for i in $(seq 1 $REAL_RUNS); do
        echo -n "    Run $i/$REAL_RUNS..."
        
        # Stop any existing nginx
        pkill -f "nginx_profiled.conf" 2>/dev/null || true
        sleep 1
        
        MEAN_ENV=""
        if [[ -n "$MEAN" ]]; then
            MEAN_ENV="SAMPLER_POISSON_MEAN_BYTES=$MEAN"
        fi
        
        # Start nginx with LD_PRELOAD
        env \
          LD_PRELOAD="./sampler/libsampler.so" \
          SAMPLER_SCHEME="$scheme" \
          SAMPLER_STATS_FILE="/tmp/nginx_${scheme}_run${i}.json" \
          $MEAN_ENV \
          "$NGINX_BIN" -p "$NGINX_PREFIX" -c "$NGINX_CONF" &
        
        sleep 2
        
        # Run wrk
        "$WRK_BIN" -t4 -c64 -d"$DURATION_WRK" "http://127.0.0.1:8080/" > "$RESULT_DIR/nginx_${scheme}_run${i}.log" 2>&1
        
        # Stop nginx
        "$NGINX_BIN" -s quit -p "$NGINX_PREFIX" -c "$NGINX_CONF" 2>/dev/null || true
        sleep 1
        
        echo " done"
    done
done

echo ""
echo "========================================="
echo "All experiments completed!"
echo "Generating aggregated report..."
echo "========================================="

# Generate results
python3 pack_results.py

echo ""
echo "Done. See results_package.txt and results/plots/"
