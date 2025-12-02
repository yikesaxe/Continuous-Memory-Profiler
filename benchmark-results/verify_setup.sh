#!/bin/bash
# Verification Script for Benchmark Setup
# Tests that all components are working correctly

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "Benchmark Results Setup Verification"
echo "=========================================="
echo ""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0

check_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((PASSED++))
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
    ((FAILED++))
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

echo "1. Checking directory structure..."
REQUIRED_DIRS=(
    "workloads"
    "workloads/synthetic"
    "workloads/curl"
    "workloads/memcached"
    "workloads/nginx"
    "stateless-sampling"
    "header-based-tracking/all-headers"
    "header-based-tracking/sample-headers"
    "results"
)

for dir in "${REQUIRED_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        check_pass "Directory exists: $dir"
    else
        check_fail "Directory missing: $dir"
    fi
done
echo ""

echo "2. Checking workload scripts..."
REQUIRED_SCRIPTS=(
    "workloads/run_workload.sh"
    "workloads/synthetic/run_monotonic.sh"
    "workloads/synthetic/run_high_reuse.sh"
    "workloads/curl/run_curl.sh"
    "workloads/memcached/run_memcached.sh"
    "workloads/nginx/run_nginx.sh"
)

for script in "${REQUIRED_SCRIPTS[@]}"; do
    if [[ -f "$script" && -x "$script" ]]; then
        check_pass "Script exists and is executable: $script"
    elif [[ -f "$script" ]]; then
        check_warn "Script exists but not executable: $script"
        chmod +x "$script"
        check_pass "Made executable: $script"
    else
        check_fail "Script missing: $script"
    fi
done
echo ""

echo "3. Checking original stateless-sampling setup..."
SAMPLER_LIB="../stateless-sampling/sampler/libsampler.so"
BENCH_BINARY="../stateless-sampling/bench/bench_alloc_patterns"

if [[ -f "$SAMPLER_LIB" ]]; then
    check_pass "Sampler library exists: $SAMPLER_LIB"
else
    check_fail "Sampler library missing: $SAMPLER_LIB"
    echo "   Run: cd ../stateless-sampling && make"
fi

if [[ -f "$BENCH_BINARY" ]]; then
    check_pass "Benchmark binary exists: $BENCH_BINARY"
else
    check_fail "Benchmark binary missing: $BENCH_BINARY"
    echo "   Run: cd ../stateless-sampling && make"
fi
echo ""

echo "4. Checking documentation..."
REQUIRED_DOCS=(
    "README.md"
    "workloads/README.md"
    "stateless-sampling/README.md"
    "header-based-tracking/all-headers/README.md"
    "header-based-tracking/sample-headers/README.md"
)

for doc in "${REQUIRED_DOCS[@]}"; do
    if [[ -f "$doc" ]]; then
        check_pass "Documentation exists: $doc"
    else
        check_fail "Documentation missing: $doc"
    fi
done
echo ""

echo "5. Testing workload driver..."
if [[ -x "workloads/run_workload.sh" ]]; then
    # Test help message
    if workloads/run_workload.sh 2>&1 | grep -q "Usage:"; then
        check_pass "Driver shows help message"
    else
        check_fail "Driver doesn't show help message"
    fi
else
    check_fail "Driver not executable"
fi
echo ""

echo "6. Running integration test (if library exists)..."
if [[ -f "$SAMPLER_LIB" && -f "$BENCH_BINARY" ]]; then
    TEST_OUTPUT="/tmp/benchmark_verify_test_$$.json"
    
    echo "   Running: monotonic workload with STATELESS_HASH"
    echo "   Output: $TEST_OUTPUT"
    
    if cd workloads && WORKLOAD_N=1000 ./run_workload.sh monotonic STATELESS_HASH "$TEST_OUTPUT" > /dev/null 2>&1; then
        check_pass "Monotonic workload executed successfully"
        
        # Check if output file was created
        if [[ -f "$TEST_OUTPUT" ]]; then
            check_pass "Stats file created: $TEST_OUTPUT"
            
            # Validate JSON
            if command -v python3 &> /dev/null; then
                if python3 -c "import json; json.load(open('$TEST_OUTPUT'))" 2>/dev/null; then
                    check_pass "Stats file is valid JSON"
                    
                    # Check key fields
                    if python3 -c "import json; d=json.load(open('$TEST_OUTPUT')); assert 'scheme' in d and 'total_allocs' in d" 2>/dev/null; then
                        check_pass "Stats file contains expected fields"
                    else
                        check_warn "Stats file missing some expected fields"
                    fi
                else
                    check_fail "Stats file is not valid JSON"
                fi
            else
                check_warn "Python3 not available, skipping JSON validation"
            fi
            
            # Cleanup
            rm -f "$TEST_OUTPUT"
        else
            check_fail "Stats file not created"
        fi
    else
        check_fail "Monotonic workload failed to execute"
    fi
    cd "$SCRIPT_DIR"
else
    check_warn "Skipping integration test (library or binary missing)"
    echo "   Build first: cd ../stateless-sampling && make"
fi
echo ""

echo "=========================================="
echo "Verification Summary"
echo "=========================================="
echo -e "${GREEN}Passed: $PASSED${NC}"
if [[ $FAILED -gt 0 ]]; then
    echo -e "${RED}Failed: $FAILED${NC}"
fi
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}✓ Setup verified successfully!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Review documentation: cat README.md"
    echo "  2. Try a workload: cd workloads && ./run_workload.sh monotonic STATELESS_HASH /tmp/test.json"
    echo "  3. View results: python3 -m json.tool /tmp/test.json"
    exit 0
else
    echo -e "${RED}✗ Setup verification failed${NC}"
    echo ""
    echo "Fix the failures above and run this script again."
    exit 1
fi
