#!/usr/bin/env python3
"""
Aggregate results from all-headers sampling experiments
"""

import json
import sys
from pathlib import Path
from collections import defaultdict
import statistics

def load_results(raw_dir):
    """Load all JSON results"""
    results = defaultdict(lambda: defaultdict(list))
    
    if not raw_dir.exists():
        print(f"ERROR: Raw results directory not found: {raw_dir}")
        return None
    
    for workload_dir in raw_dir.iterdir():
        if not workload_dir.is_dir():
            continue
        workload = workload_dir.name
        
        for scheme_dir in workload_dir.iterdir():
            if not scheme_dir.is_dir():
                continue
            scheme = scheme_dir.name
            
            for json_file in scheme_dir.glob("run_*.json*"):
                try:
                    with open(json_file) as f:
                        data = json.load(f)
                        results[workload][scheme].append(data)
                except Exception as e:
                    print(f"WARNING: Failed to load {json_file}: {e}")
    
    return results

def compute_stats(values):
    """Compute statistics"""
    if not values:
        return {"mean": 0, "std": 0, "min": 0, "max": 0, "p50": 0, "p95": 0, "p99": 0, "count": 0}
    
    return {
        "mean": statistics.mean(values),
        "std": statistics.stdev(values) if len(values) > 1 else 0,
        "min": min(values),
        "max": max(values),
        "p50": statistics.median(values),
        "p95": statistics.quantiles(values, n=20)[18] if len(values) > 1 else values[0],
        "p99": statistics.quantiles(values, n=100)[98] if len(values) > 1 else values[0],
        "count": len(values)
    }

def aggregate_results(results):
    """Aggregate by workload and scheme"""
    aggregated = {}
    
    for workload, schemes in results.items():
        aggregated[workload] = {}
        
        for scheme, runs in schemes.items():
            sample_rate_allocs = [r.get("sample_rate_allocs", 0) for r in runs]
            sample_rate_bytes = [r.get("sample_rate_bytes", 0) for r in runs]
            windows_zero = [r.get("windows_zero_sampled", 0) for r in runs]
            windows_total = [r.get("windows_total", 1) for r in runs]
            total_allocs = [r.get("total_allocs", 0) for r in runs]
            sampled_allocs = [r.get("sampled_allocs", 0) for r in runs]
            
            dead_zone_rates = []
            for i in range(len(windows_zero)):
                if windows_total[i] > 0:
                    dead_zone_rates.append(windows_zero[i] / windows_total[i])
            
            agg = {
                "sample_rate_allocs": compute_stats(sample_rate_allocs),
                "sample_rate_bytes": compute_stats(sample_rate_bytes),
                "dead_zone_rate": compute_stats(dead_zone_rates),
                "total_allocs": compute_stats(total_allocs),
                "sampled_allocs": compute_stats(sampled_allocs),
                "runs": len(runs)
            }
            
            # PAGE_HASH specific metrics
            if "PAGE" in scheme:
                unique_pages = [r.get("approx_unique_pages", 0) for r in runs]
                sampled_pages = [r.get("approx_sampled_pages", 0) for r in runs]
                page_coverage = []
                for i in range(len(unique_pages)):
                    if unique_pages[i] > 0:
                        page_coverage.append(sampled_pages[i] / unique_pages[i])
                
                agg["approx_unique_pages"] = compute_stats(unique_pages)
                agg["approx_sampled_pages"] = compute_stats(sampled_pages)
                agg["page_coverage"] = compute_stats(page_coverage)
            
            aggregated[workload][scheme] = agg
    
    return aggregated

def write_summary_json(aggregated, output_file):
    """Write JSON summary"""
    with open(output_file, 'w') as f:
        json.dump(aggregated, f, indent=2)
    print(f"✓ Wrote JSON: {output_file}")

def write_summary_txt(aggregated, output_file):
    """Write text summary"""
    with open(output_file, 'w') as f:
        f.write("="*80 + "\n")
        f.write("All-Headers Sampling Experiments - Results Summary\n")
        f.write("="*80 + "\n\n")
        
        for workload, schemes in sorted(aggregated.items()):
            f.write(f"\n{'='*80}\n")
            f.write(f"Workload: {workload.upper()}\n")
            f.write(f"{'='*80}\n\n")
            
            for scheme, metrics in sorted(schemes.items()):
                f.write(f"Scheme: {scheme}\n")
                f.write(f"  Runs: {metrics['runs']}\n")
                f.write(f"  Total Allocations: {metrics['total_allocs']['mean']:.0f}\n")
                
                sr_allocs = metrics['sample_rate_allocs']
                f.write(f"  Sample Rate (allocs): {sr_allocs['mean']:.6f} ± {sr_allocs['std']:.6f} ")
                f.write(f"[p50: {sr_allocs['p50']:.6f}, p95: {sr_allocs['p95']:.6f}]\n")
                
                sr_bytes = metrics['sample_rate_bytes']
                f.write(f"  Sample Rate (bytes): {sr_bytes['mean']:.6f} ± {sr_bytes['std']:.6f}\n")
                
                dz = metrics['dead_zone_rate']
                f.write(f"  Dead Zone Rate: {dz['mean']:.4f} ± {dz['std']:.4f}\n")
                
                if 'page_coverage' in metrics:
                    pc = metrics['page_coverage']
                    f.write(f"  Page Coverage: {pc['mean']:.4f} ± {pc['std']:.4f}\n")
                    f.write(f"  Unique Pages: {metrics['approx_unique_pages']['mean']:.0f}\n")
                    f.write(f"  Sampled Pages: {metrics['approx_sampled_pages']['mean']:.0f}\n")
                
                f.write("\n")
    
    print(f"✓ Wrote text: {output_file}")

def main():
    script_dir = Path(__file__).parent.absolute()
    raw_dir = script_dir / "raw"
    
    print("="*60)
    print("Aggregating All-Headers Results")
    print("="*60)
    
    print(f"\nLoading from: {raw_dir}")
    results = load_results(raw_dir)
    
    if results is None or not results:
        print("ERROR: No results found")
        return 1
    
    total_runs = sum(len(runs) for schemes in results.values() for runs in schemes.values())
    print(f"Loaded {total_runs} runs")
    
    print("\nAggregating...")
    aggregated = aggregate_results(results)
    
    print("\nWriting summaries...")
    write_summary_json(aggregated, script_dir / "all_headers_results_summary.json")
    write_summary_txt(aggregated, script_dir / "all_headers_results_summary.txt")
    
    print("\n" + "="*60)
    print("✓ Complete")
    print("="*60)
    print("\nNext: python3 make_plots.py")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
