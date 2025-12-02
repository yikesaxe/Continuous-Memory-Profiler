# Benchmark Results Organization

This directory organizes experiments for comparing memory sampling strategies across different implementation approaches.

## Directory Structure

```
benchmark-results/
├── workloads/                      # Shared workload runners (START HERE!)
│   ├── run_workload.sh             # Unified driver script
│   ├── synthetic/                  # Microbenchmarks (monotonic, high-reuse)
│   ├── curl/                       # Compiler workload
│   ├── memcached/                  # Key-value store workload
│   ├── nginx/                      # Web server workload
│   └── README.md                   # Workload documentation
│
├── stateless-sampling/             # TRUE stateless experiments
│   └── (experiments comparing hash variants, stateless Poisson, etc.)
│
├── header-based-tracking/          # Header-based implementations
│   ├── all-headers/                # Every allocation gets header (current impl)
│   └── sample-headers/             # Only sampled allocations get headers
│
└── results/                        # Aggregated results across experiments
    └── (comparative analyses, plots, tables)
```

---

## Overview

This structure separates three concerns:

1. **Workloads** - The applications/benchmarks we run (what we measure)
2. **Implementations** - Different sampling approaches (what we test)
3. **Results** - Aggregated comparative data (what we learn)

### Why This Structure?

The goal is to answer: **"Which sampling strategy is best for production profiling?"**

We need to compare:
- True stateless (hash only, no state)
- Header-based with universal headers (current implementation)
- Header-based with selective headers (only sampled allocs)
- Different hash functions
- Different sampling rates

By standardizing workloads, we can run the same tests across all implementations.

---

## Quick Start

### 1. Build Prerequisites

First, build the original sampler:

```bash
cd ../stateless-sampling
make
cd ../benchmark-results
```

### 2. Run a Simple Test

```bash
cd workloads
./run_workload.sh monotonic STATELESS_HASH /tmp/test.json
```

### 3. View Results

```bash
cat /tmp/test.json
# or
python -m json.tool /tmp/test.json
```

---

## Workloads

All experiments use these standardized workloads:

| Workload | Type | Allocations | Tests For |
|----------|------|-------------|-----------|
| **monotonic** | Synthetic | 100k | Leak detection (best case) |
| **high-reuse** | Synthetic | ~100k | Address reuse bias (worst case) |
| **curl** | Real-world | ~3.7k | Compiler overhead |
| **memcached** | Real-world | ~258 | Key-value store overhead |
| **nginx** | Real-world | ~43 | Web server overhead |

See [`workloads/README.md`](workloads/README.md) for detailed documentation.

---

## Implementation Approaches

### 1. Stateless Sampling (True)

**Directory:** `stateless-sampling/`

**Approach:** No headers at all, re-hash on free:

```c
void *malloc(size_t size) {
    void *ptr = real_malloc(size);
    if (hash(ptr) & 0xFF == 0) {
        // Store in external hash table
        record_sample(ptr, size);
    }
    return ptr;
}

void free(void *ptr) {
    if (hash(ptr) & 0xFF == 0) {
        // Lookup in hash table
        remove_sample(ptr);
    }
    real_free(ptr);
}
```

**Variants to test:**
- Different hash functions (XOR-shift, FNV-1a, murmur3)
- Different sampling rates (1/128, 1/256, 1/512)
- Page-based hashing
- Stateless Poisson (hash determines if sample, but counter is deterministic from address)

**Trade-offs:**
- ✅ Zero inline overhead (no headers)
- ✅ Fast decision (just hash)
- ❌ Requires external storage (hash table)
- ❌ Address reuse bias

### 2. Header-Based: All Headers

**Directory:** `header-based-tracking/all-headers/`

**Approach:** Every allocation gets a header (current implementation):

```c
void *malloc(size_t size) {
    void *raw = real_malloc(size + 16);
    Header *h = (Header *)raw;
    h->magic = 0xDEADBEEF;
    h->is_sampled = should_sample(raw, size);  // Decision
    h->size = size;
    return (char *)raw + 16;
}
```

**Trade-offs:**
- ✅ Simple to implement
- ✅ Can read header on free (no external state)
- ❌ 16 bytes overhead per allocation (100% of allocs)
- ❌ Cache pollution

### 3. Header-Based: Sample Headers Only

**Directory:** `header-based-tracking/sample-headers/`

**Approach:** Only sampled allocations get headers:

```c
void *malloc(size_t size) {
    bool sampled = should_sample_before_alloc(size);
    if (sampled) {
        void *raw = real_malloc(size + 16);
        Header *h = (Header *)raw;
        h->magic = 0xDEADBEEF;
        register_has_header(raw + 16);  // Track in hash table
        return (char *)raw + 16;
    } else {
        return real_malloc(size);  // No header!
    }
}
```

**Trade-offs:**
- ✅ Low memory overhead (headers only on 0.4% of allocs)
- ❌ Requires hash table to track "has header or not"
- ❌ More complex realloc handling

---

## Experimental Questions

### Q1: Is true stateless cheaper than headers?

**Setup:**
- Run all workloads with:
  - `stateless-sampling/hash-only`
  - `header-based-tracking/all-headers` (current)
  - `header-based-tracking/sample-headers`

**Metrics:**
- Memory overhead (bytes per allocation)
- CPU overhead (throughput, latency)
- Implementation complexity

**Hypothesis:** Sample-headers should be cheapest, all-headers most expensive.

### Q2: Does hash choice matter?

**Setup:**
- Run `stateless-sampling/` with different hashes:
  - XOR-shift (current)
  - FNV-1a
  - Murmur3
  - CityHash

**Metrics:**
- Sample rate achievement (0.39% target)
- Variance across runs
- CPU overhead

**Hypothesis:** All hashes should achieve ~0.39%, but differ in variance.

### Q3: What sampling rate is optimal?

**Setup:**
- Run all implementations with rates: 1/64, 1/128, 1/256, 1/512, 1/1024

**Metrics:**
- Leak detection accuracy
- Overhead vs rate
- Statistical confidence

**Hypothesis:** 1/256 is sweet spot (enough samples, low overhead).

### Q4: Can we fix address reuse bias?

**Setup:**
- Test on `high-reuse` workload:
  - Plain hash (fails)
  - Hash with salt from allocation time
  - Hybrid (Poisson for hot paths)

**Metrics:**
- Sample rate consistency
- Dead zones (windows with zero samples)

**Hypothesis:** Time-salted hash or hybrid should reduce variance.

---

## Running Experiments

### Single Workload, Single Scheme

```bash
cd workloads
./run_workload.sh monotonic STATELESS_HASH /tmp/mono.json
```

### Batch Experiments

```bash
#!/bin/bash
# Compare schemes on monotonic workload

SCHEMES=("STATELESS_HASH" "POISSON_HEADER" "HYBRID" "PAGE_HASH")

for scheme in "${SCHEMES[@]}"; do
    for run in {1..20}; do
        OUTPUT="results/monotonic_${scheme}_run${run}.json"
        ./workloads/run_workload.sh monotonic "$scheme" "$OUTPUT"
        sleep 0.5
    done
done

# Analyze
python analyze_results.py results/monotonic_*.json
```

### Cross-Implementation Comparison

```bash
# Test same workload with different implementations
# (once implementations are added to their directories)

# 1. All-headers (current)
LD_PRELOAD=../stateless-sampling/sampler/libsampler.so \
./workloads/run_workload.sh monotonic STATELESS_HASH results/all_headers.json

# 2. Sample-headers (future)
LD_PRELOAD=header-based-tracking/sample-headers/libsampler_selective.so \
./workloads/run_workload.sh monotonic STATELESS_HASH results/sample_headers.json

# 3. True stateless (future)
LD_PRELOAD=stateless-sampling/libsampler_stateless.so \
./workloads/run_workload.sh monotonic STATELESS_HASH results/true_stateless.json
```

---

## Results Organization

Store aggregated results in `results/`:

```
results/
├── monotonic/
│   ├── all_schemes_comparison.json
│   ├── variance_analysis.png
│   └── overhead_vs_rate.png
├── high_reuse/
│   ├── hash_bias_analysis.json
│   └── dead_zones_by_scheme.png
├── real_world/
│   ├── curl_overhead.json
│   ├── memcached_throughput.png
│   └── nginx_latency.png
└── summary_report.md
```

---

## Relationship to Original Code

**This does NOT replace `stateless-sampling/`**. Instead:

- `stateless-sampling/` contains the original research + implementation
- `benchmark-results/` organizes new experiments using that foundation
- `benchmark-results/workloads/` wraps the original workloads for reuse

The original code remains fully functional. This is purely organizational.

---

## Implementation Roadmap

### Phase 1: Setup (Current)
- ✅ Directory structure
- ✅ Workload wrappers
- ✅ Unified driver
- ✅ Documentation

### Phase 2: True Stateless
- [ ] Implement hash-only sampler (no headers)
- [ ] Add external hash table for tracking
- [ ] Test hash function variants
- [ ] Measure overhead vs all-headers

### Phase 3: Selective Headers
- [ ] Implement sample-headers approach
- [ ] Add "has header" tracking
- [ ] Handle realloc edge cases
- [ ] Compare overhead to all-headers

### Phase 4: Analysis
- [ ] Python scripts for result aggregation
- [ ] Statistical analysis (variance, confidence intervals)
- [ ] Visualization (plots, tables)
- [ ] Final recommendation document

---

## Contributing

When adding new experiments:

1. **Use existing workloads** - Don't create new ones unless necessary
2. **Follow naming convention** - `<category>/<implementation>/`
3. **Document thoroughly** - Add README in your experiment directory
4. **Share results** - Put aggregated data in `results/`

---

## References

- Original implementation: [`../stateless-sampling/`](../stateless-sampling/)
- Workload documentation: [`workloads/README.md`](workloads/README.md)
- Original research docs:
  - [`../stateless-sampling/FOR_DANIELLE_START_HERE.md`](../stateless-sampling/FOR_DANIELLE_START_HERE.md)
  - [`../stateless-sampling/VISUAL_EXPLANATION.md`](../stateless-sampling/VISUAL_EXPLANATION.md)
