# Quick Start - All-Headers Sampling

## What This Is

Experiments where **every allocation has a 16-byte header**, testing different sampling strategies:
- `HEADER_HASH` - Hash-based sampling with headers
- `HEADER_PAGE_HASH` - Page-based hash sampling
- `HEADER_POISSON_BYTES` - Poisson byte-counter sampling (jemalloc-style)
- `HEADER_HYBRID` - Small=Poisson, Large=Hash

**Key difference from true stateless:** Headers on **every allocation** (16 MB per 1M allocations).

---

## Run Experiments (3 Commands)

```bash
cd /home/axel/Workspace/Continous-Memory-Profiler/benchmark-results/header-based-tracking/all-headers

# 1. Run experiments
python3 run_all_headers_experiments.py --runs 10

# Or faster (synthetic only)
python3 run_all_headers_experiments.py --skip-real-world --runs 5

# 2. Aggregate
python3 aggregate_all_headers_results.py

# 3. Plot
python3 make_plots.py
```

---

## Manual Test

```bash
# Test HEADER_HASH on monotonic
SAMPLER_SCHEME=HEADER_HASH \
SAMPLER_STATS_FILE=/tmp/test.json \
SAMPLER_LIB=$(pwd)/libsampler_all_headers.so \
WORKLOAD_N=10000 \
../../workloads/run_workload.sh monotonic HEADER_HASH /tmp/test.json

# View
python3 -m json.tool /tmp/test.json.*
```

---

## Understanding Output

```json
{
  "scheme": "HEADER_HASH",
  "all_headers": true,
  "header_size": 16,           // ← 16 bytes per allocation!
  "total_allocs": 100000,
  "sampled_allocs": 390,
  "sample_rate_allocs": 0.003900,
  "sampled_frees": 370,        // ← Exact (not estimated)
  "windows_zero_sampled": 0
}
```

**Key difference:** `sampled_frees` is **exact** (reads header), not estimated.

---

## Scheme Comparison

| Scheme | Decision | Best For |
|--------|----------|----------|
| HEADER_HASH | Hash address | Speed, simplicity |
| HEADER_PAGE_HASH | Hash page | Large working sets |
| HEADER_POISSON_BYTES | Byte counter | Consistency, no bias |
| HEADER_HYBRID | Size-dependent | Balanced approach |

All have **same memory overhead** (16 bytes/alloc).

---

## Memory Overhead

For 1 million allocations:
- **All-headers:** 16 MB (this approach)
- **True stateless:** 0 bytes
- **Sample-headers:** 62.5 KB (future)

**Trade-off:** This is the simplest but most expensive approach.

---

## Files Structure

```
all-headers/
├── QUICKSTART.md              # This file
├── results.md                 # Detailed results
│
├── libsampler_all_headers.so  # Library ✓
├── sampler_all_headers.c/h    # Source
│
├── run_all_headers_experiments.py     ✓
├── aggregate_all_headers_results.py   ✓
├── make_plots.py                      ✓
│
├── raw/                       # Results
└── plots/                     # Visualizations
```

---

## Troubleshooting

**Library not found:**
```bash
make clean && make
```

**Benchmark binary missing:**
```bash
cd ../../../stateless-sampling && make
```

**Python errors:**
```bash
pip3 install matplotlib
```

---

## Comparison Points

Compare this to:
1. **True stateless** (`../../stateless-sampling/`)
   - 0 memory overhead vs 16 MB
   - Estimated frees vs exact frees

2. **Sample-headers** (`../sample-headers/`)
   - 16 MB vs 62 KB
   - Simple vs complex implementation

---

*Created: Dec 2, 2024*
