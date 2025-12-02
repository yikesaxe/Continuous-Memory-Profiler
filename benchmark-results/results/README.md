# Combined Results

This directory contains the unified analysis combining all three sampling implementations.

## Main Output

**[`combined_results.md`](combined_results.md)** - The final unified report

This file is auto-generated from the three implementations' results:
- True Stateless (`../stateless-sampling/`)
- All-Headers (`../header-based-tracking/all-headers/`)
- Sample-Headers (`../header-based-tracking/sample-headers/`)

---

## Generating the Report

```bash
# After running all experiments:
python3 combine_results.py
```

This script:
1. Reads all `*_results_summary.json` files
2. Combines them into unified tables
3. Generates recommendations
4. Outputs to `combined_results.md`

---

## What's in the Report

### Overview
- Memory overhead comparison (0 vs 1.1 MB vs 16 MB)
- Feature comparison matrix

### Per-Implementation Results
- Sample rate tables (across schemes and workloads)
- Dead zone analysis
- Implementation-specific metrics

### Recommendations
- By use case (production, debugging, research)
- By allocation count (<1M, 1-100M, >100M)
- Best schemes per approach
- Schemes to avoid

### Key Insights
- Memory vs accuracy trade-offs
- Hash-based limitations
- Implementation complexity analysis
- Practical guidelines

---

## Prerequisites

Before running `combine_results.py`, ensure experiments are complete:

```bash
# 1. True Stateless
cd ../stateless-sampling
python3 run_stateless_experiments.py --skip-real-world --runs 5
python3 aggregate_stateless_results.py

# 2. All-Headers
cd ../header-based-tracking/all-headers
python3 run_all_headers_experiments.py --skip-real-world --runs 5
python3 aggregate_all_headers_results.py

# 3. Sample-Headers
cd ../header-based-tracking/sample-headers
python3 run_sample_headers_experiments.py --skip-real-world --runs 5
python3 aggregate_sample_headers_results.py

# 4. Combine
cd ../../results
python3 combine_results.py
```

**Or use the helper:**
```bash
cd ..
bash quick_run_all.sh
```

---

## Output Status

Run `python3 combine_results.py` to check which implementations have results:

```
Found results: 0/3 implementations
  ⚠️ True Stateless: No results yet
  ⚠️ All-Headers: No results yet  
  ⚠️ Sample-Headers: No results yet
```

The combined report will indicate which experiments need to be run.

---

## Files

- `combine_results.py` - Results combiner script
- `combined_results.md` - Generated unified report ⭐
- `README.md` - This file

---

*Central location for unified analysis across all implementations*
