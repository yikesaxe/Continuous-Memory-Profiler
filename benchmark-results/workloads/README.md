# Benchmark Workloads

This directory contains standardized workload runners for evaluating memory sampling strategies. All workloads share a common interface and reuse existing code from the `stateless-sampling/` implementation.

## Directory Structure

```
workloads/
├── run_workload.sh          # Unified driver (USE THIS!)
├── synthetic/               # Synthetic microbenchmarks
│   ├── run_monotonic.sh     # Monotonic heap workload
│   └── run_high_reuse.sh    # High address reuse workload
├── curl/                    # Real-world: compiler workload
│   └── run_curl.sh
├── memcached/               # Real-world: key-value store
│   └── run_memcached.sh
├── nginx/                   # Real-world: web server
│   └── run_nginx.sh
└── README.md               # This file
```

---

## Quick Start

### Prerequisites

1. **Build the sampler library first:**
   ```bash
   cd ../../stateless-sampling
   make
   cd -
   ```

2. **Install dependencies** (for real-world workloads):
   ```bash
   # Memcached workload
   sudo apt-get install memcached memtier-benchmark
   
   # Nginx workload  
   sudo apt-get install nginx
   
   # WRK (build from source if not packaged)
   git clone https://github.com/wg/wrk.git
   cd wrk && make && sudo cp wrk /usr/local/bin/
   ```

### Running a Workload

**Use the unified driver:**

```bash
./run_workload.sh <workload> <scheme> <stats_file> [env_vars...]
```

**Examples:**

```bash
# Monotonic heap with stateless hash
./run_workload.sh monotonic STATELESS_HASH /tmp/mono_hash.json

# High reuse with Poisson sampling (64KB mean)
./run_workload.sh high-reuse POISSON_HEADER /tmp/reuse.json SAMPLER_POISSON_MEAN_BYTES=65536

# Curl compilation with hybrid sampling
./run_workload.sh curl HYBRID /tmp/curl.json

# Memcached with custom configuration
./run_workload.sh memcached STATELESS_HASH /tmp/memcached.json MEMCACHED_PORT=11212
```

---

## Workloads

### 1. Monotonic Heap (`monotonic`)

**What it does:**
- Allocates 100,000 objects
- Frees 95% of them
- Intentionally leaks 5% (5,000 objects)

**What it tests:**
- Can sampling detect memory leaks?
- Does the sampler estimate live heap size correctly?

**Use case:** Best-case scenario for hash-based sampling (addresses are mostly unique).

**Configuration:**
```bash
WORKLOAD_N=100000              # Number of allocations (default: 100000)
WORKLOAD_MIN_SIZE=16           # Min allocation size (default: 16)
WORKLOAD_MAX_SIZE=4096         # Max allocation size (default: 4096)
```

**Example:**
```bash
./run_workload.sh monotonic STATELESS_HASH /tmp/mono.json WORKLOAD_N=50000
```

**Expected results:**
- Sample rate: ~0.39% (1 in 256)
- Should detect ~20 leaked samples → estimate ~5,000 leaked objects

---

### 2. High Address Reuse (`high-reuse`)

**What it does:**
- Allocates into only 100 "hot slots"
- Repeatedly free + reallocate same addresses (100,000 iterations)
- Forces allocator to reuse addresses heavily

**What it tests:**
- Does hash-based sampling go "blind" when addresses repeat?
- Variance in sampling rates across runs

**Use case:** Worst-case scenario for stateless hash (high address reuse).

**Configuration:**
```bash
WORKLOAD_SLOTS=100             # Number of hot slots (default: 100)
WORKLOAD_ITERATIONS=100000     # Churn iterations (default: 100000)
WORKLOAD_MIN_SIZE=16           # Min allocation size (default: 16)
WORKLOAD_MAX_SIZE=256          # Max allocation size (default: 256)
```

**Example:**
```bash
./run_workload.sh high-reuse POISSON_HEADER /tmp/reuse.json WORKLOAD_SLOTS=50
```

**Expected results:**
- Hash: ~0.37% sampling (works, but high variance)
- Poisson: ~0.22% sampling (consistent)
- PAGE_HASH: 0% sampling (fails on small working set)

---

### 3. Curl Compilation (`curl`)

**What it does:**
- Clones curl source (if not present)
- Compiles with `make -j$(nproc)` under profiling

**What it tests:**
- Overhead on a real compiler workload
- Allocation patterns during software build

**Use case:** Representative of developer workflows (builds, compilers).

**Configuration:**
```bash
CURL_DIR=curl                  # Curl source directory (default: curl)
MAKE_JOBS=8                    # Parallel jobs (default: nproc)
```

**Example:**
```bash
./run_workload.sh curl HYBRID /tmp/curl.json MAKE_JOBS=4
```

**Expected results:**
- Low allocation count (~3,700 allocs)
- Overhead: <7%

---

### 4. Memcached (`memcached`)

**What it does:**
- Starts memcached server under profiling
- Runs `memtier_benchmark` load test against it
- Measures throughput and latency

**What it tests:**
- Overhead on a production key-value store
- Allocation patterns under sustained load

**Use case:** Representative of in-memory caching workloads.

**Configuration:**
```bash
MEMCACHED_PORT=11211           # Port (default: 11211)
MEMCACHED_THREADS=4            # Server threads (default: 4)
MEMTIER_CLIENTS=4              # Clients per thread (default: 4)
MEMTIER_THREADS=4              # Client threads (default: 4)
MEMTIER_REQUESTS=50000         # Requests per client (default: 50000)
MEMTIER_PIPELINE=16            # Pipeline depth (default: 16)
```

**Example:**
```bash
./run_workload.sh memcached STATELESS_HASH /tmp/memcached.json MEMTIER_REQUESTS=100000
```

**Expected results:**
- Very low allocation count during serving (~258 allocs)
- Overhead: ~6%

---

### 5. Nginx (`nginx`)

**What it does:**
- Starts nginx under profiling
- Runs `wrk` HTTP benchmark against it
- Measures request throughput

**What it tests:**
- Overhead on a production web server
- Allocation patterns under HTTP load

**Use case:** Representative of web serving workloads.

**Configuration:**
```bash
NGINX_PORT=8080                # Port (default: 8080)
NGINX_WORKERS=2                # Worker processes (default: 2)
WRK_THREADS=4                  # WRK threads (default: 4)
WRK_CONNECTIONS=100            # Concurrent connections (default: 100)
WRK_DURATION=30s               # Test duration (default: 30s)
NGINX_CONF=path/to/nginx.conf  # Config file
```

**Example:**
```bash
./run_workload.sh nginx POISSON_HEADER /tmp/nginx.json WRK_DURATION=60s
```

**Expected results:**
- Very low allocation count during serving (~43 allocs)
- Most allocations happen at startup

---

## Sampler Schemes

All workloads support these sampling schemes:

### `STATELESS_HASH`
- **Algorithm:** XOR-shift hash on address, sample if `(hash & 0xFF) == 0`
- **Target rate:** 1 in 256 (0.39%)
- **Pros:** Zero state, fast
- **Cons:** Address reuse bias

### `POISSON_HEADER`
- **Algorithm:** Decrement byte counter, sample when `counter <= 0`
- **Target rate:** Configurable via `SAMPLER_POISSON_MEAN_BYTES`
- **Pros:** Statistically sound, immune to address reuse
- **Cons:** Thread-local state (8 bytes/thread)

### `PAGE_HASH`
- **Algorithm:** Hash page number (`addr >> 12`), sample all allocs on sampled pages
- **Target rate:** 1 in 256 pages
- **Pros:** Zero state
- **Cons:** Fails on small working sets (<1000 pages)

### `HYBRID`
- **Algorithm:** Small allocs (<256 bytes) use Poisson, large allocs use Hash
- **Target rate:** Mixed
- **Pros:** Balances consistency and performance
- **Cons:** More complex

---

## Environment Variables

### Required (set automatically by `run_workload.sh`)
- `SAMPLER_SCHEME` - Sampling strategy (STATELESS_HASH, POISSON_HEADER, etc.)
- `SAMPLER_STATS_FILE` - Path for JSON output

### Optional (override as needed)
- `SAMPLER_POISSON_MEAN_BYTES` - Mean bytes between samples (default: 4096)
- `SAMPLER_LIB` - Path to libsampler.so (default: ../../stateless-sampling/sampler/libsampler.so)
- `BENCH_BINARY` - Path to bench_alloc_patterns (default: ../../stateless-sampling/bench/bench_alloc_patterns)

### Workload-Specific
See each workload's configuration section above.

---

## Output Format

All workloads produce a JSON file with these fields:

```json
{
  "pid": 12345,
  "scheme": "STATELESS_HASH",
  "total_allocs": 100000,
  "sampled_allocs": 390,
  "sample_rate_allocs": 0.003900,
  "sampled_live_allocs_estimate": 20,
  "windows_zero_sampled": 0,
  "size_bins": {
    "0-32": { "total": 1000, "sampled": 4 },
    ...
  }
}
```

**Key metrics:**
- `sample_rate_allocs` - Did we hit 0.39% target?
- `windows_zero_sampled` - Dead zones (windows of 100k allocs with zero samples)
- `sampled_live_allocs_estimate` - Estimated live objects (for leak detection)

---

## Running Multiple Experiments

**Batch script example:**

```bash
#!/bin/bash
SCHEMES=("STATELESS_HASH" "POISSON_HEADER" "HYBRID" "PAGE_HASH")

for scheme in "${SCHEMES[@]}"; do
    for i in {1..10}; do
        echo "Run $i with $scheme"
        ./run_workload.sh monotonic "$scheme" "/tmp/mono_${scheme}_${i}.json"
        sleep 1
    done
done

# Aggregate results
python ../aggregate_results.py /tmp/mono_*.json
```

---

## Troubleshooting

### "Benchmark binary not found"
```bash
cd ../../stateless-sampling
make
```

### "memcached not found"
```bash
sudo apt-get install memcached memtier-benchmark
```

### "wrk not found"
```bash
git clone https://github.com/wg/wrk.git
cd wrk && make && sudo cp wrk /usr/local/bin/
```

### "Address already in use"
Change the port:
```bash
./run_workload.sh memcached STATELESS_HASH /tmp/stats.json MEMCACHED_PORT=11212
```

---

## Implementation Notes

### Design Philosophy

1. **Reuse, don't duplicate**: All scripts call existing binaries from `stateless-sampling/`
2. **Relative paths**: Scripts use relative paths (work from repo root)
3. **Standard interface**: All workloads accept same env vars
4. **Fail fast**: Scripts check dependencies and error clearly

### Relationship to Original Code

These workload wrappers **do not replace** the original `stateless-sampling/` code. They provide:
- Standardized interface across workloads
- Easier batch experimentation
- Clear documentation

The original scripts in `stateless-sampling/real_world/` still work independently.

---

## Future Work

Planned additions:
- **Steady-state workload** (mode 2 from bench_alloc_patterns)
- **Multi-threaded stress test** (8+ concurrent threads)
- **Redis workload** (to reproduce jemalloc failures)
- **Python analysis scripts** (for aggregating results)

---

## References

- Original implementation: `../../stateless-sampling/`
- Documentation: `../../stateless-sampling/FOR_DANIELLE_START_HERE.md`
- Visual explanation: `../../stateless-sampling/VISUAL_EXPLANATION.md`
