#!/bin/bash
# Quick test to verify the stateless sampling setup

set -e

echo "========================================"
echo "Testing Stateless Sampling Setup"
echo "========================================"
echo ""

# Check if library exists
if [[ ! -f "libsampler_stateless.so" ]]; then
    echo "ERROR: Library not found. Run 'make' first."
    exit 1
fi
echo "✓ Library found: libsampler_stateless.so"

# Check if workload script exists
WORKLOAD_SCRIPT="../workloads/run_workload.sh"
if [[ ! -x "$WORKLOAD_SCRIPT" ]]; then
    echo "ERROR: Workload script not found or not executable: $WORKLOAD_SCRIPT"
    exit 1
fi
echo "✓ Workload script found"

# Check if Python scripts exist
for script in run_stateless_experiments.py aggregate_stateless_results.py make_plots.py; do
    if [[ ! -f "$script" ]]; then
        echo "ERROR: Script not found: $script"
        exit 1
    fi
    chmod +x "$script" 2>/dev/null || true
done
echo "✓ Python scripts found"

# Run a quick test with STATELESS_HASH_XOR
echo ""
echo "Running quick test (monotonic workload with HASH_XOR)..."
TEST_OUTPUT="/tmp/stateless_test_$$.json"

SAMPLER_SCHEME=STATELESS_HASH_XOR \
SAMPLER_STATS_FILE="$TEST_OUTPUT" \
SAMPLER_LIB="$(pwd)/libsampler_stateless.so" \
WORKLOAD_N=1000 \
"$WORKLOAD_SCRIPT" monotonic STATELESS_HASH_XOR "$TEST_OUTPUT" > /dev/null 2>&1

if [[ ! -f "$TEST_OUTPUT" ]]; then
    echo "✗ Test failed: Stats file not created"
    exit 1
fi

# Verify JSON
if ! python3 -c "import json; json.load(open('$TEST_OUTPUT'))" 2>/dev/null; then
    echo "✗ Test failed: Invalid JSON"
    exit 1
fi

# Check key fields
SCHEME=$(python3 -c "import json; print(json.load(open('$TEST_OUTPUT'))['scheme'])")
if [[ "$SCHEME" != "STATELESS_HASH_XOR" ]]; then
    echo "✗ Test failed: Wrong scheme in output"
    exit 1
fi

echo "✓ Quick test passed!"
echo ""
echo "Sample output:"
python3 -m json.tool "$TEST_OUTPUT" | head -20
echo "..."

# Cleanup
rm -f "$TEST_OUTPUT"

echo ""
echo "========================================"
echo "✓ Setup verified successfully!"
echo "========================================"
echo ""
echo "Next steps:"
echo "  1. Run full experiments:"
echo "     python3 run_stateless_experiments.py --runs 10"
echo ""
echo "  2. Aggregate results:"
echo "     python3 aggregate_stateless_results.py"
echo ""
echo "  3. Generate plots:"
echo "     python3 make_plots.py"
echo ""
echo "  4. View results:"
echo "     cat results.md"
