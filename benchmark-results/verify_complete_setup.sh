#!/bin/bash
# Verify complete benchmark-results setup

echo "============================================================"
echo "Benchmark Results - Complete Setup Verification"
echo "============================================================"
echo ""

PASS=0
FAIL=0
WARN=0

check_file() {
    if [[ -f "$1" ]]; then
        echo "✓ $1"
        ((PASS++))
        return 0
    else
        echo "✗ MISSING: $1"
        ((FAIL++))
        return 1
    fi
}

check_exec() {
    if [[ -x "$1" ]]; then
        echo "✓ $1 (executable)"
        ((PASS++))
        return 0
    else
        echo "⚠ $1 (not executable)"
        ((WARN++))
        return 1
    fi
}

# Core documentation
echo "📚 Core Documentation:"
check_file "README.md"
check_file "MASTER_GUIDE.md"
check_file "COMPARISON.md"
echo ""

# Workloads
echo "🔧 Workloads:"
check_exec "workloads/run_workload.sh"
check_exec "workloads/synthetic/run_monotonic.sh"
check_exec "workloads/synthetic/run_high_reuse.sh"
check_file "workloads/README.md"
echo ""

# True Stateless
echo "1️⃣ True Stateless Implementation:"
check_file "stateless-sampling/libsampler_stateless.so"
check_file "stateless-sampling/sampler_stateless.c"
check_file "stateless-sampling/sampler_stateless.h"
check_file "stateless-sampling/Makefile"
check_exec "stateless-sampling/run_stateless_experiments.py"
check_exec "stateless-sampling/aggregate_stateless_results.py"
check_exec "stateless-sampling/make_plots.py"
check_file "stateless-sampling/README.md"
check_file "stateless-sampling/QUICKSTART.md"
check_file "stateless-sampling/results.md"
echo ""

# All-Headers
echo "2️⃣ All-Headers Implementation:"
check_file "header-based-tracking/all-headers/libsampler_all_headers.so"
check_file "header-based-tracking/all-headers/sampler_all_headers.c"
check_file "header-based-tracking/all-headers/sampler_all_headers.h"
check_file "header-based-tracking/all-headers/Makefile"
check_exec "header-based-tracking/all-headers/run_all_headers_experiments.py"
check_exec "header-based-tracking/all-headers/aggregate_all_headers_results.py"
check_exec "header-based-tracking/all-headers/make_plots.py"
check_file "header-based-tracking/all-headers/README.md"
check_file "header-based-tracking/all-headers/QUICKSTART.md"
check_file "header-based-tracking/all-headers/results.md"
echo ""

# Sample-Headers
echo "3️⃣ Sample-Headers Implementation:"
check_file "header-based-tracking/sample-headers/libsampler_sample_headers.so"
check_file "header-based-tracking/sample-headers/sampler_sample_headers.c"
check_file "header-based-tracking/sample-headers/sampler_sample_headers.h"
check_file "header-based-tracking/sample-headers/Makefile"
check_exec "header-based-tracking/sample-headers/run_sample_headers_experiments.py"
check_exec "header-based-tracking/sample-headers/aggregate_sample_headers_results.py"
check_exec "header-based-tracking/sample-headers/make_plots.py"
check_file "header-based-tracking/sample-headers/README.md"
check_file "header-based-tracking/sample-headers/QUICKSTART.md"
check_file "header-based-tracking/sample-headers/results.md"
echo ""

# Results
echo "📊 Results Aggregation:"
check_exec "results/combine_results.py"
check_file "results/README.md"
echo ""

# Helper scripts
echo "🚀 Helper Scripts:"
check_exec "quick_run_all.sh"
echo ""

echo "============================================================"
echo "Summary:"
echo "  ✓ Passed: $PASS"
if [[ $WARN -gt 0 ]]; then
    echo "  ⚠ Warnings: $WARN"
fi
if [[ $FAIL -gt 0 ]]; then
    echo "  ✗ Failed: $FAIL"
fi
echo "============================================================"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo "✅ Setup complete and verified!"
    echo ""
    echo "Quick start:"
    echo "  bash quick_run_all.sh"
    echo ""
    echo "Or read:"
    echo "  cat MASTER_GUIDE.md"
    exit 0
else
    echo "❌ Setup incomplete"
    echo "Fix missing files above"
    exit 1
fi
