# Stateless Sampling Evaluation Harness

This project implements an `LD_PRELOAD`-based sampling library (`libsampler.so`) and a set of synthetic benchmarks to evaluate different memory sampling strategies for live heap profiling.

## Directory Structure

*   `sampler/`: Contains the sampling library.
    *   `sampler.c`: Main logic for intercepting malloc/free and implementing sampling schemes.
    *   `sampler.h`: Header definitions for the custom allocation header.
*   `bench/`: Contains the synthetic benchmark generator.
    *   `bench_alloc_patterns.c`: Generates monotonic, steady-state, and high-reuse workloads.
*   `real_world/`: Contains helper scripts for real-world benchmarks (memcached, nginx).

## Prerequisites (Debian 12)

To run the real-world benchmarks (`memcached` and `nginx`), you need the following packages:

*   memcached
*   memtier-benchmark
*   nginx
*   wrk (install from source if not packaged)
*   build-essential, git, pkg-config, libssl-dev

Example installation commands:

```bash
sudo apt-get update
sudo apt-get install -y memcached memtier-benchmark nginx build-essential git pkg-config libssl-dev

# Install wrk from source
git clone https://github.com/wg/wrk.git
cd wrk && make
sudo cp wrk /usr/local/bin/
```

## Building

To build everything:

```bash
make
```

## Sampling Schemes

The library supports four schemes, controlled by `SAMPLER_SCHEME`:

1.  **STATELESS_HASH** (`S1`):
    *   Uses XOR-shift hash on the pointer address.
    *   Sample rate: ~1/256 (Hash & 0xFF == 0).
    *   Zero memory overhead (state), minimal CPU overhead.
    *   Risk: Address reuse bias.

2.  **POISSON_HEADER** (`S2`):
    *   Uses a geometric distribution (Poisson process) based on bytes allocated.
    *   Target mean is tunable via `SAMPLER_POISSON_MEAN_BYTES` (default 4096).
    *   Statistically sound for allocation rates.

3.  **HYBRID** (`S3`):
    *   Small allocations (< 256 bytes): Use Poisson.
    *   Large allocations: Use Address Hash.

4.  **PAGE_HASH** (`S4`):
    *   Uses XOR-shift hash on the *page number* (address >> 12).
    *   Samples *all* allocations on specific sampled pages.
    *   Sample rate: ~1/256 of pages.
    *   **Goal**: Reduce risk of hot-spots landing in unsampled regions by sampling entire regions.
    *   **Risk**: It samples pages, not individual objects. For a workload that uses only K distinct pages, the probability that none of them are sampled when using a mask of 0xFF is roughly `(255/256)^K`. This can be quite high if K is small (e.g., < 1000). If the application working set fits in a small number of pages, `PAGE_HASH` may go completely blind.

## Running Benchmarks

### 1. Synthetic Workloads

**Monotonic Workload (alloc N, free 95%)**:
```bash
# Stateless full-address hash
SAMPLER_SCHEME=STATELESS_HASH \
SAMPLER_STATS_FILE=stats_mono_hash.json \
LD_PRELOAD=./sampler/libsampler.so \
./bench/bench_alloc_patterns 1 100000 16 4096

# Page-based hash
SAMPLER_SCHEME=PAGE_HASH \
SAMPLER_STATS_FILE=stats_mono_page.json \
LD_PRELOAD=./sampler/libsampler.so \
./bench/bench_alloc_patterns 1 100000 16 4096

# Hybrid
SAMPLER_SCHEME=HYBRID \
SAMPLER_POISSON_MEAN_BYTES=65536 \
SAMPLER_STATS_FILE=stats_mono_hybrid.json \
LD_PRELOAD=./sampler/libsampler.so \
./bench/bench_alloc_patterns 1 100000 16 4096
```

**High-Reuse Workload (Stress Test)**:
Allocates into a small pool of hot slots (e.g., 100) and churns them 100k times. This forces the allocator to reuse the same few addresses repeatedly.
```bash
# 100 hot slots, 100k iterations

# Stateless full-address hash
SAMPLER_SCHEME=STATELESS_HASH \
SAMPLER_STATS_FILE=stats_reuse_hash.json \
LD_PRELOAD=./sampler/libsampler.so \
./bench/bench_alloc_patterns 4 100 100000 16 256

# Page-based hash
SAMPLER_SCHEME=PAGE_HASH \
SAMPLER_STATS_FILE=stats_reuse_page.json \
LD_PRELOAD=./sampler/libsampler.so \
./bench/bench_alloc_patterns 4 100 100000 16 256
```

### 2. Real-World Workloads

**Compiling `curl`**:

```bash
# Clone
git clone https://github.com/curl/curl.git
cd curl
./buildconf && ./configure

# Run Stateless Hash
make clean
SAMPLER_SCHEME=STATELESS_HASH \
SAMPLER_STATS_FILE=/tmp/stats_curl_hash.json \
LD_PRELOAD=/path/to/stateless-sampling/sampler/libsampler.so \
time make -j$(nproc)

# Run Poisson
make clean
SAMPLER_SCHEME=POISSON_HEADER \
SAMPLER_POISSON_MEAN_BYTES=4096 \
SAMPLER_STATS_FILE=/tmp/stats_curl_poisson.json \
LD_PRELOAD=/path/to/stateless-sampling/sampler/libsampler.so \
time make -j$(nproc)

# Run Page Hash
make clean
SAMPLER_SCHEME=PAGE_HASH \
SAMPLER_STATS_FILE=/tmp/stats_curl_page.json \
LD_PRELOAD=/path/to/stateless-sampling/sampler/libsampler.so \
time make -j$(nproc)

# Run Hybrid
make clean
SAMPLER_SCHEME=HYBRID \
SAMPLER_POISSON_MEAN_BYTES=65536 \
SAMPLER_STATS_FILE=/tmp/stats_curl_hybrid.json \
LD_PRELOAD=/path/to/stateless-sampling/sampler/libsampler.so \
time make -j$(nproc)
```

## Metrics

The JSON output contains:
*   `scheme`, `scheme_id`: Configuration info.
*   `total_allocs` / `sampled_allocs`: Raw counts.
*   `sample_rate_allocs` / `sample_rate_bytes`: Derived effective sample rates.
*   `sampled_live_allocs_estimate`: Estimate of current live objects.
*   `windows_zero_sampled`: "Dead Zone" metric. Counts windows of 100,000 allocations where *zero* samples were taken. High numbers indicate bias.
*   `window_remainder_allocs`: Remainder of the last partial window. Useful for interpreting `windows_zero_sampled` on short runs.
*   `approx_unique_pages` / `approx_sampled_pages`: (For PAGE_HASH only) Approximate count of unique pages seen vs sampled. Helps diagnose when working set size causes sampling blindness.
