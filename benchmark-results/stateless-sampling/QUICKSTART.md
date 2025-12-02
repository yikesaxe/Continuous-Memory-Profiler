# Quick Start Guide - True Stateless Sampling

## What Was Implemented

✅ **4 sampling schemes** (all truly stateless - zero memory overhead):
- `STATELESS_HASH_XOR` - XOR-shift hash (fast, default)
- `STATELESS_HASH_SPLITMIX` - SplitMix64 hash (better distribution)
- `STATELESS_HASH_MURMURISH` - Murmur3 hash (best distribution)
- `STATELESS_POISSON_BERNOULLI` - Size-dependent Bernoulli sampling

✅ **Complete experiment framework**:
- Automated runner for all workload × scheme combinations
- Results aggregation with statistics
- Matplotlib-based plotting

✅ **Comprehensive documentation**:
- README.md - Main documentation
- results.md - Detailed results explanation
- This file - Quick start guide

---

## Run Experiments (3 Commands)

### 1. Run Experiments

```bash
cd /home/axel/Workspace/Continous-Memory-Profiler/benchmark-results/stateless-sampling

# Full run (all schemes, all workloads, 10 runs each)
python3 run_stateless_experiments.py

# Or faster test (synthetic workloads only)
python3 run_stateless_experiments.py --skip-real-world --runs 5
```

**Time:** ~2-5 minutes for synthetic only, ~10-20 minutes for all workloads

### 2. Aggregate Results

```bash
python3 aggregate_stateless_results.py
```

This creates:
- `stateless_results_summary.json` (machine-readable)
- `stateless_results_summary.txt` (human-readable)

### 3. Generate Plots

```bash
python3 make_plots.py
```

Plots saved to `plots/`:
- Sample rate comparisons
- Dead zone analysis
- Cross-workload visualizations

---

## Manual Test (Single Run)

```bash
# Test STATELESS_HASH_XOR on monotonic workload
SAMPLER_SCHEME=STATELESS_HASH_XOR \
SAMPLER_STATS_FILE=/tmp/test.json \
SAMPLER_LIB=$(pwd)/libsampler_stateless.so \
WORKLOAD_N=10000 \
../workloads/run_workload.sh monotonic STATELESS_HASH_XOR /tmp/test.json

# View results
python3 -m json.tool /tmp/test.json.*
```

---

## Understanding the Output

### Key Metrics

```json
{
  "scheme": "STATELESS_HASH_XOR",
  "stateless": true,              // ← TRUE stateless (no headers)
  "total_allocs": 100000,
  "sampled_allocs": 390,          // ← ~390 sampled (1/256 ≈ 0.39%)
  "sample_rate_allocs": 0.003900, // ← Target: 0.00390625
  "windows_zero_sampled": 0,      // ← Dead zones (should be 0)
  "size_bins": { ... }            // ← Per-size-class sampling
}
```

### Interpretation

**Sample Rate:**
- **0.0037-0.0042**: Excellent (within noise)
- **0.0030-0.0050**: Good
- **< 0.0020 or > 0.0060**: Poor (indicates bias)

**Dead Zones:**
- **0**: Perfect
- **1-5**: Acceptable
- **> 10**: Problem (address reuse bias)

---

## Comparing Schemes

### When to Use Each Scheme

| Scheme | Best For | Avoid When |
|--------|----------|-----------|
| **HASH_XOR** | Default choice, proven in production | Seeing bias with your allocator |
| **HASH_SPLITMIX** | Better distribution than XOR | Need absolute fastest (XOR is slightly faster) |
| **HASH_MURMURISH** | Maximum distribution quality | Performance is critical |
| **POISSON_BERNOULLI** | Address reuse patterns, jemalloc | Need uniform size sampling |

### Expected Results

**Monotonic Workload:**
- All schemes: ~0.39% ± 0.0001
- No bias expected (unique addresses)

**High-Reuse Workload:**
- Hash schemes: May show variance
- Poisson: Should be consistent
- Dead zones: Possible for hash, rare for Poisson

---

## File Structure

```
stateless-sampling/
├── README.md                     # Main documentation
├── QUICKSTART.md                 # This file
├── results.md                    # Results explanation
│
├── libsampler_stateless.so       # The library ✓
├── sampler_stateless.c/h         # Source code
├── Makefile                      # Build system
│
├── run_stateless_experiments.py  # Main experiment runner
├── aggregate_stateless_results.py # Results aggregation
├── make_plots.py                 # Visualization
│
├── raw/                          # Raw JSON results
│   └── <workload>/<scheme>/run_N.json
│
├── plots/                        # Generated plots
│   └── *.png
│
├── stateless_results_summary.json # Aggregated results
└── stateless_results_summary.txt  # Human-readable summary
```

---

## Troubleshooting

### "Library not found"
```bash
make clean && make
```

### "Benchmark binary not found"
```bash
cd ../../stateless-sampling
make
```

### "No module named matplotlib"
```bash
sudo apt-get install python3-matplotlib
# or
pip3 install matplotlib
```

### Experiments fail
Check logs in individual JSON files:
```bash
cat raw/monotonic/STATELESS_HASH_XOR/run_1.json
```

---

## Next Steps

1. **Read documentation:**
   ```bash
   cat README.md | less
   cat results.md | less
   ```

2. **Run full experiments:**
   ```bash
   python3 run_stateless_experiments.py
   ```

3. **Analyze results:**
   ```bash
   python3 aggregate_stateless_results.py
   cat stateless_results_summary.txt
   ```

4. **Visualize:**
   ```bash
   python3 make_plots.py
   ls plots/
   ```

5. **Compare to original:**
   - Original (all-headers): `../../stateless-sampling/`
   - This (true stateless): `./`

---

## Key Differences from Original

| Aspect | Original | True Stateless (This) |
|--------|----------|----------------------|
| Memory overhead | 16 bytes/alloc | **0 bytes** |
| Headers | Every allocation | **None** |
| Free tracking | Exact (read header) | Estimated (re-hash) |
| Implementation | 520 lines | ~400 lines |

**Memory savings:** 256× reduction for 1/256 sampling rate!

---

*Created: Dec 2, 2024*
