# Quick Start - Sample-Headers

## What This Is

**Headers only on sampled allocations** - the most memory-efficient header-based approach.

**Three schemes:**
- `SAMPLE_HEADERS_POISSON_MAP` - Poisson decision + map tracking (recommended)
- `SAMPLE_HEADERS_HASH_MAP` - Hash decision + map (wasteful - for comparison)
- `SAMPLE_HEADERS_EBPF_INSPIRED` - eBPF model prototype

**Key innovation:** Reduce memory by 15× compared to all-headers.

---

## Memory Overhead Comparison

For 1 million allocations:

| Approach | Overhead | Reduction |
|----------|----------|-----------|
| All-headers | 16 MB | Baseline |
| **Sample-headers** | **1.1 MB** | **15×** |
| True stateless | 0 | ∞ |

---

## Run Experiments (3 Commands)

```bash
cd /home/axel/Workspace/Continous-Memory-Profiler/benchmark-results/header-based-tracking/sample-headers

# 1. Run experiments
python3 run_sample_headers_experiments.py --runs 10

# Or faster (synthetic only)
python3 run_sample_headers_experiments.py --skip-real-world --runs 5

# 2. Aggregate
python3 aggregate_sample_headers_results.py

# 3. Plot
python3 make_plots.py
```

---

## Manual Test

```bash
# Test POISSON_MAP on monotonic
SAMPLER_SCHEME=SAMPLE_HEADERS_POISSON_MAP \
SAMPLER_STATS_FILE=/tmp/test.json \
SAMPLER_LIB=$(pwd)/libsampler_sample_headers.so \
WORKLOAD_N=10000 \
../../workloads/run_workload.sh monotonic SAMPLE_HEADERS_POISSON_MAP /tmp/test.json

# View results
python3 -m json.tool /tmp/test.json.*
```

---

## Understanding Output

```json
{
  "scheme": "SAMPLE_HEADERS_POISSON_MAP",
  "sample_headers": true,
  "total_allocs": 100000,
  "sampled_allocs": 220,          // Only 220 got headers!
  "sample_rate_allocs": 0.002200,
  "sampled_frees": 209,           // Exact (from header)
  "map_peak_size": 11,            // Peak live sampled
  "map_inserts": 220,             // Hash table inserts
  "map_lookups": 100000,          // Lookups on every free
  "map_deletes": 209              // Removes when freeing sampled
}
```

**Key metrics:**
- `map_peak_size`: Max live sampled allocations (memory for tracking)
- `map_ops_per_1k_allocs`: Hash table overhead

---

## Scheme Comparison

| Scheme | Decision | Memory | Speed | Recommended |
|--------|----------|--------|-------|-------------|
| POISSON_MAP | Poisson | Low | Medium | ✅ Yes |
| HASH_MAP | Hash | Low | Slow (2x alloc) | ❌ No |
| EBPF_INSPIRED | Poisson | Low | Medium | ⚠️ Prototype |

**Use POISSON_MAP** - it's the only practical one.

---

## Why This Approach?

### Advantages over All-Headers

✅ **15× memory reduction** (1.1 MB vs 16 MB)
✅ **Exact free tracking** (vs estimated in stateless)
✅ **Scalable** to 100M allocations

### Disadvantages

❌ **Complex implementation** (hash table + realloc logic)
❌ **Hash table overhead** (1 MB fixed + mutex contention)
❌ **Can't use hash-based decisions** (need address first)

---

## Files Structure

```
sample-headers/
├── QUICKSTART.md                      # This file
├── results.md                         # Detailed results
│
├── libsampler_sample_headers.so       # Library ✓
├── sampler_sample_headers.c/h         # Source (~500 lines)
│
├── run_sample_headers_experiments.py  ✓
├── aggregate_sample_headers_results.py ✓
├── make_plots.py                      ✓
│
├── raw/                               # Results
└── plots/                             # Plots
```

---

## Troubleshooting

**Build failed:**
```bash
make clean && make
```

**Segfault:**
- Hash table mutex contention
- Check `map_peak_size` (too many entries?)

**Low sample rate:**
- Expected for Poisson (~0.22% vs 0.39% for hash)
- Due to size distribution

---

## Next Steps

1. **Run experiments:**
   ```bash
   python3 run_sample_headers_experiments.py
   ```

2. **Compare to other approaches:**
   - All-headers: `../all-headers/`
   - True stateless: `../../stateless-sampling/`

3. **Read results:**
   ```bash
   cat results.md | less
   cat sample_headers_results_summary.txt
   ```

---

*Most memory-efficient header-based approach*
