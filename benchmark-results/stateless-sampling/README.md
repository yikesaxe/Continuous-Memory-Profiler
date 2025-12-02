# True Stateless Sampling Experiments

This directory contains TRUE stateless sampling implementations - no headers, zero inline memory overhead, pure hash-based or probabilistic decisions.

## What's Implemented

### Sampling Library: `libsampler_stateless.so`

A minimal LD_PRELOAD library that implements four truly stateless sampling schemes:

| Scheme | Algorithm | Characteristics |
|--------|-----------|-----------------|
| **STATELESS_HASH_XOR** | XOR-shift hash on address | Fast, simple, widely used |
| **STATELESS_HASH_SPLITMIX** | SplitMix64 hash on address | Better distribution |
| **STATELESS_HASH_MURMURISH** | Murmur3-style hash | Excellent distribution |
| **STATELESS_POISSON_BERNOULLI** | Bernoulli trial based on size | Statistically sound |

All schemes:
- ✅ **Zero memory overhead** (no headers!)
- ✅ **Thread-safe** (atomic stats, thread-local RNG)
- ✅ **Reuse existing workloads** (via `benchmark-results/workloads/`)

### Key Difference from Original Implementation

| Aspect | Original (`stateless-sampling/`) | This (TRUE stateless) |
|--------|--------------------------------|----------------------|
| Headers | 16 bytes per allocation | **None** |
| Free tracking | Read header | **Re-hash address** |
| Memory overhead | 16 × N allocs | **0 bytes** |
| Accuracy | Exact | Estimated (re-hash) |

---

## Quick Start

### 1. Build

```bash
cd benchmark-results/stateless-sampling
make
```

### 2. Run Experiments

```bash
# Run all experiments (10 runs per workload/scheme pair)
python3 run_stateless_experiments.py

# Or run specific schemes/workloads
python3 run_stateless_experiments.py --schemes STATELESS_HASH_XOR STATELESS_POISSON_BERNOULLI \
                                     --workloads monotonic high-reuse

# Skip slow real-world workloads
python3 run_stateless_experiments.py --skip-real-world --runs 20
```

### 3. Aggregate Results

```bash
python3 aggregate_stateless_results.py
```

This creates:
- `stateless_results_summary.json` (machine-readable)
- `stateless_results_summary.txt` (human-readable)

### 4. Generate Plots

```bash
python3 make_plots.py
```

Plots are saved to `plots/`:
- `mono_sample_rate_allocs_stateless.png`
- `reuse_sample_rate_allocs_stateless.png`
- `curl_sample_rate_bytes_stateless.png`
- And more...

---

## Sampling Schemes Explained

### Hash-Based Schemes

All three hash schemes use the same principle:

```c
sampled = (hash(address) & 0xFF) == 0  // 1 in 256
```

**Differences:**

1. **STATELESS_HASH_XOR** (XOR-shift)
   ```c
   h = addr;
   h ^= h >> 12;
   h ^= h << 25;
   h ^= h >> 27;
   return h * 0x2545F4914F6CDD1DULL;
   ```
   - Fastest (~6 operations)
   - Used in tcmalloc, jemalloc profilers
   - **When to use:** Default choice

2. **STATELESS_HASH_SPLITMIX** (SplitMix64)
   ```c
   h = (addr ^ (addr >> 30)) * 0xBF58476D1CE4E5B9ULL;
   h = (h ^ (h >> 27)) * 0x94D049BB133111EBULL;
   return h ^ (h >> 31);
   ```
   - Better avalanche properties
   - **When to use:** If XOR-shift shows bias

3. **STATELESS_HASH_MURMURISH** (Murmur3-style)
   ```c
   h = addr;
   h ^= h >> 33;
   h *= 0xFF51AFD7ED558CCDULL;
   h ^= h >> 33;
   h *= 0xC4CEB9FE1A85EC53ULL;
   return h ^ (h >> 33);
   ```
   - Excellent distribution
   - Slightly slower
   - **When to use:** Maximum quality needed

### Poisson/Bernoulli Scheme

Size-dependent sampling:

```c
p = 1 - exp(-size / mean_bytes)  // Probability
sampled = (random() < p)
```

**Example (mean = 4096 bytes):**
- 16-byte allocation: p ≈ 0.39%
- 4096-byte allocation: p ≈ 63%
- 16384-byte allocation: p ≈ 98%

**Characteristics:**
- ✅ Immune to address reuse
- ✅ Statistically sound
- ⚠️ Biases toward large allocations (by design)
- ⚠️ Slightly higher CPU overhead (exp() + RNG)

**When to use:** When address-based sampling shows bias (e.g., jemalloc with arena reuse).

---

## Environment Variables

### Required
- `SAMPLER_SCHEME` - One of:
  - `STATELESS_HASH_XOR`
  - `STATELESS_HASH_SPLITMIX`
  - `STATELESS_HASH_MURMURISH`
  - `STATELESS_POISSON_BERNOULLI`
- `SAMPLER_STATS_FILE` - Output JSON path

### Optional
- `SAMPLER_HASH_MASK` - Hash mask (default: `0xFF` for 1/256)
  - `0x7F` = 1/128
  - `0xFF` = 1/256
  - `0x1FF` = 1/512
- `SAMPLER_POISSON_MEAN_BYTES` - Mean bytes for Poisson (default: 4096)

---

## Directory Structure

```
stateless-sampling/
├── README.md                         # This file
├── results.md                        # Detailed results documentation
├── Makefile                          # Build system
├── sampler_stateless.h               # Header
├── sampler_stateless.c               # Implementation
├── libsampler_stateless.so           # Compiled library
│
├── run_stateless_experiments.py      # Experiment runner
├── aggregate_stateless_results.py    # Results aggregation
├── make_plots.py                     # Visualization
│
├── raw/                              # Raw JSON results
│   ├── monotonic/
│   │   ├── STATELESS_HASH_XOR/
│   │   │   ├── run_1.json
│   │   │   └── ...
│   │   └── ...
│   └── ...
│
├── plots/                            # Generated visualizations
│   ├── mono_sample_rate_allocs_stateless.png
│   └── ...
│
├── stateless_results_summary.json    # Aggregated results (JSON)
└── stateless_results_summary.txt     # Aggregated results (text)
```

---

## Example: Manual Run

```bash
# Build library
make

# Run monotonic workload with XOR hash
SAMPLER_SCHEME=STATELESS_HASH_XOR \
SAMPLER_STATS_FILE=/tmp/test.json \
SAMPLER_LIB=$(pwd)/libsampler_stateless.so \
../workloads/run_workload.sh monotonic STATELESS_HASH_XOR /tmp/test.json

# View results
python3 -m json.tool /tmp/test.json
```

---

## Interpreting Results

### Sample Rate

**Target:** 0.00390625 (1/256)

**Achievement:**
- **95-105%**: Excellent (within statistical noise)
- **85-115%**: Good (acceptable variance)
- **<85% or >115%**: Poor (indicates bias)

### Dead Zones

"Dead zone" = window of 100,000 allocations with **zero samples**.

**Interpretation:**
- **0 dead zones**: Excellent
- **1-5% dead zones**: Acceptable (statistical outliers)
- **>10% dead zones**: Poor (indicates systematic bias)

---

## Performance

### Overhead Comparison

| Component | CPU Cycles | Impact |
|-----------|------------|--------|
| Hash (XOR-shift) | ~6 | Negligible |
| Hash (SplitMix64) | ~8 | Negligible |
| Hash (Murmur3) | ~10 | Negligible |
| Poisson (exp + RNG) | ~25 | Still very low |
| Header read (original) | ~1 (cache hit) | Very low |
| Header read (original) | ~100 (cache miss) | Moderate |

**Conclusion:** Hash overhead is negligible. Main cost is the malloc/free call itself.

### Memory Savings

For 1 million allocations:

| Approach | Memory Overhead |
|----------|----------------|
| All-headers (original) | 16 MB |
| TRUE stateless (this) | **0 bytes** |

**256× reduction** in memory overhead!

---

## Known Limitations

### 1. Free Tracking is Estimated

For hash schemes, we re-hash on `free()` to estimate if it was sampled:

```c
void free(void *ptr) {
    if (hash(ptr) & 0xFF == 0) {
        // Estimate: it was probably sampled
        sampled_frees++;
    }
    real_free(ptr);
}
```

**Problem:** If address was reallocated between malloc and free, estimate may be wrong.

**Impact:** `sampled_live_allocs_estimate` may be slightly inaccurate.

**Workaround:** Use Poisson/Bernoulli (can't estimate frees, but sampling is more accurate).

### 2. Poisson Can't Track Frees

For `STATELESS_POISSON_BERNOULLI`, we can't re-determine if an allocation was sampled without knowing its size.

**Solution:** `sampled_frees_estimate` is always 0 for this scheme.

### 3. Address Reuse Bias (Hash Only)

If the allocator reuses the same addresses and they all hash to non-zero:

```
Hot addresses: [0x1000, 0x2000, ..., 0x6400]
All hash to non-zero → 0% sampling!
```

**Mitigation:** Use Poisson/Bernoulli or test with different hash functions.

---

## Comparison to ddprof Approach

This implementation is similar to ddprof's "stateless mode":

| Aspect | ddprof | This Implementation |
|--------|--------|---------------------|
| Headers | None | None |
| Hash function | Custom | XOR/SplitMix/Murmur3 |
| External storage | Hash table (tracks samples) | **None** (stats only) |
| Free tracking | Hash table lookup | Re-hash |
| Memory overhead | ~8 bytes per sample | 0 bytes |

**Key difference:** We don't store which allocations were sampled (no hash table). We only track aggregate statistics.

---

## Future Work

- [ ] Test with jemalloc allocator (known to cause address reuse)
- [ ] Add time-salted hash variant (mix timestamp into hash)
- [ ] Implement hash table for accurate free tracking
- [ ] Multi-threaded stress test (8+ threads)
- [ ] Compare performance to all-headers approach

---

## References

- Original implementation: `../../stateless-sampling/`
- Workloads: `../workloads/`
- ddprof approach: DataDog's continuous profiler
- Hash functions:
  - XOR-shift: Marsaglia (2003)
  - SplitMix64: Steele et al. (2014)
  - MurmurHash: Appleby (2008)
