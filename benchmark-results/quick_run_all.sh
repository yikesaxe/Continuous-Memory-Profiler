#!/bin/bash
# Quick run all three implementations (synthetic workloads only)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RUNS=${RUNS:-5}

echo "========================================"
echo "Running All Sampling Implementations"
echo "========================================"
echo "Runs per (scheme, workload): $RUNS"
echo "Workloads: synthetic only (monotonic, high-reuse)"
echo "Estimated time: 5-10 minutes"
echo "========================================"
echo ""

# 1. True Stateless
echo "1/3: Running True Stateless experiments..."
cd stateless-sampling
python3 run_stateless_experiments.py --skip-real-world --runs "$RUNS"
python3 aggregate_stateless_results.py
python3 make_plots.py
cd ..
echo "✓ True Stateless complete"
echo ""

# 2. All-Headers
echo "2/3: Running All-Headers experiments..."
cd header-based-tracking/all-headers
python3 run_all_headers_experiments.py --skip-real-world --runs "$RUNS"
python3 aggregate_all_headers_results.py
python3 make_plots.py
cd ../..
echo "✓ All-Headers complete"
echo ""

# 3. Sample-Headers
echo "3/3: Running Sample-Headers experiments..."
cd header-based-tracking/sample-headers
python3 run_sample_headers_experiments.py --skip-real-world --runs "$RUNS"
python3 aggregate_sample_headers_results.py
python3 make_plots.py
cd ../..
echo "✓ Sample-Headers complete"
echo ""

# 4. Combined report
echo "Generating combined report..."
cd results
python3 combine_results.py
cd ..

echo ""
echo "========================================"
echo "✓ All experiments complete!"
echo "========================================"
echo ""
echo "Results:"
echo "  • True Stateless: stateless-sampling/stateless_results_summary.txt"
echo "  • All-Headers: header-based-tracking/all-headers/all_headers_results_summary.txt"
echo "  • Sample-Headers: header-based-tracking/sample-headers/sample_headers_results_summary.txt"
echo "  • Combined: results/combined_results.md ⭐"
echo ""
echo "Plots:"
echo "  • ls stateless-sampling/plots/"
echo "  • ls header-based-tracking/all-headers/plots/"
echo "  • ls header-based-tracking/sample-headers/plots/"
echo ""
echo "View combined report:"
echo "  cat results/combined_results.md"
