#!/bin/bash
# Summarize timing results from all benchmarks

echo "=========================================="
echo "  Sampling Overhead Summary"
echo "=========================================="
echo ""

extract_metric() {
    local file=$1
    local pattern=$2
    grep "$pattern" "$file" 2>/dev/null | awk '{print $NF}'
}

summarize_pair() {
    local name=$1
    local poisson_file=$2
    local hash_file=$3
    
    if [ ! -f "$poisson_file" ] || [ ! -f "$hash_file" ]; then
        return
    fi
    
    echo "-------------------------------------------"
    echo "$name"
    echo "-------------------------------------------"
    
    local pois_calls=$(extract_metric "$poisson_file" "Total decisions:")
    local pois_avg=$(extract_metric "$poisson_file" "Avg cycles:")
    local pois_total=$(extract_metric "$poisson_file" "Total cycles:")
    local pois_samples=$(extract_metric "$poisson_file" "Samples taken:" | head -1)
    
    local hash_calls=$(extract_metric "$hash_file" "Total decisions:")
    local hash_avg=$(extract_metric "$hash_file" "Avg cycles:")
    local hash_total=$(extract_metric "$hash_file" "Total cycles:")
    local hash_samples=$(extract_metric "$hash_file" "Samples taken:" | head -1)
    
    echo "Poisson:"
    echo "  Decisions: $pois_calls"
    echo "  Samples:   $pois_samples"
    echo "  Avg/call:  $pois_avg cycles"
    echo "  Total:     $pois_total cycles"
    echo ""
    echo "Hash:"
    echo "  Decisions: $hash_calls"
    echo "  Samples:   $hash_samples"
    echo "  Avg/call:  $hash_avg cycles"
    echo "  Total:     $hash_total cycles"
    echo ""
    
    # Calculate speedup
    if [ ! -z "$pois_avg" ] && [ ! -z "$hash_avg" ]; then
        speedup=$(awk "BEGIN {printf \"%.2f\", $pois_avg / $hash_avg}")
        diff=$(awk "BEGIN {printf \"%.2f\", $pois_avg - $hash_avg}")
        echo "Hash is ${speedup}x faster (saves $diff cycles/decision)"
    fi
    echo ""
}

# Check if we have any timing files
if ! ls timing_*.txt 1> /dev/null 2>&1; then
    echo "No timing results found."
    echo "Run ./run_timed_benchmarks.sh first"
    exit 1
fi

# Summarize each workload pair
summarize_pair "Monotonic Heap Workload" "timing_mono_poisson.txt" "timing_mono_hash.txt"
summarize_pair "Steady State Pool Workload" "timing_steady_poisson.txt" "timing_steady_hash.txt"
summarize_pair "High Address Reuse Workload" "timing_reuse_poisson.txt" "timing_reuse_hash.txt"

# Combined mode summary
if [ -f "timing_combined.txt" ]; then
    echo "-------------------------------------------"
    echo "Combined Mode (Both schemes on same workload)"
    echo "-------------------------------------------"
    
    pois_avg=$(grep -A 5 "Poisson Sampling:" timing_combined.txt | grep "Avg cycles:" | awk '{print $NF}')
    hash_avg=$(grep -A 5 "Hash Sampling:" timing_combined.txt | grep "Avg cycles:" | awk '{print $NF}')
    
    echo "On identical allocation sequence:"
    echo "  Poisson: $pois_avg cycles/decision"
    echo "  Hash:    $hash_avg cycles/decision"
    
    if [ ! -z "$pois_avg" ] && [ ! -z "$hash_avg" ]; then
        speedup=$(awk "BEGIN {printf \"%.2f\", $pois_avg / $hash_avg}")
        echo "  Speedup: ${speedup}x"
    fi
    echo ""
fi

echo "=========================================="
echo ""
echo "For detailed per-test output, see timing_*.txt"
