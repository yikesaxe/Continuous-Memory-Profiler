#!/usr/bin/env python3
"""
Aggregate sample-headers results
"""

import json
import sys
from pathlib import Path
from collections import defaultdict
import statistics

def load_results(raw_dir):
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
            
            # Map-specific metrics
            peak_map_size = [r.get("map_peak_size", 0) for r in runs]
            map_inserts = [r.get("map_inserts", 0) for r in runs]
            map_lookups = [r.get("map_lookups", 0) for r in runs]
            map_deletes = [r.get("map_deletes", 0) for r in runs]
            
            # Compute map ops per 1000 allocs
            map_ops_per_1k = []
            for i in range(len(total_allocs)):
                if total_allocs[i] > 0:
                    total_ops = map_inserts[i] + map_lookups[i] + map_deletes[i]
                    map_ops_per_1k.append((total_ops / total_allocs[i]) * 1000)
            
            dead_zone_rates = []
            for i in range(len(windows_zero)):
                if windows_total[i] > 0:
                    dead_zone_rates.append(windows_zero[i] / windows_total[i])
            
            aggregated[workload][scheme] = {
                "sample_rate_allocs": compute_stats(sample_rate_allocs),
                "sample_rate_bytes": compute_stats(sample_rate_bytes),
                "dead_zone_rate": compute_stats(dead_zone_rates),
                "total_allocs": compute_stats(total_allocs),
                "sampled_allocs": compute_stats(sampled_allocs),
                "map_peak_size": compute_stats(peak_map_size),
                "map_ops_per_1k_allocs": compute_stats(map_ops_per_1k),
                "runs": len(runs)
            }
    
    return aggregated

def write_summary_json(aggregated, output_file):
    with open(output_file, 'w') as f:
        json.dump(aggregated, f, indent=2)
    print(f"✓ Wrote JSON: {output_file}")

def write_summary_txt(aggregated, output_file):
    with open(output_file, 'w') as f:
        f.write("="*80 + "\n")
        f.write("Sample-Headers Experiments - Results Summary\n")
        f.write("(Headers only on sampled allocations)\n")
        f.write("="*80 + "\n\n")
        
        for workload, schemes in sorted(aggregated.items()):
            f.write(f"\n{'='*80}\n")
            f.write(f"Workload: {workload.upper()}\n")
            f.write(f"{'='*80}\n\n")
            
            for scheme, metrics in sorted(schemes.items()):
                f.write(f"Scheme: {scheme}\n")
                f.write(f"  Runs: {metrics['runs']}\n")
                f.write(f"  Total Allocations: {metrics['total_allocs']['mean']:.0f}\n")
                f.write(f"  Sampled Allocations: {metrics['sampled_allocs']['mean']:.0f}\n")
                
                sr_allocs = metrics['sample_rate_allocs']
                f.write(f"  Sample Rate (allocs): {sr_allocs['mean']:.6f} ± {sr_allocs['std']:.6f} ")
                f.write(f"[p50: {sr_allocs['p50']:.6f}]\n")
                
                sr_bytes = metrics['sample_rate_bytes']
                f.write(f"  Sample Rate (bytes): {sr_bytes['mean']:.6f} ± {sr_bytes['std']:.6f}\n")
                
                dz = metrics['dead_zone_rate']
                f.write(f"  Dead Zone Rate: {dz['mean']:.4f} ± {dz['std']:.4f}\n")
                
                # Map metrics
                peak = metrics['map_peak_size']
                f.write(f"  Peak Map Size: {peak['mean']:.0f} ± {peak['std']:.0f} ")
                f.write(f"[max: {peak['max']:.0f}]\n")
                
                ops = metrics['map_ops_per_1k_allocs']
                f.write(f"  Map Ops per 1k allocs: {ops['mean']:.1f} ± {ops['std']:.1f}\n")
                
                f.write("\n")
    
    print(f"✓ Wrote text: {output_file}")

def main():
    script_dir = Path(__file__).parent.absolute()
    raw_dir = script_dir / "raw"
    
    print("="*60)
    print("Aggregating Sample-Headers Results")
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
    write_summary_json(aggregated, script_dir / "sample_headers_results_summary.json")
    write_summary_txt(aggregated, script_dir / "sample_headers_results_summary.txt")
    
    print("\n" + "="*60)
    print("✓ Complete")
    print("="*60)
    print("\nNext: python3 make_plots.py")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
