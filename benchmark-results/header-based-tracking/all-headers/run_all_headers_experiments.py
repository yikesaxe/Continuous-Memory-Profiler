#!/usr/bin/env python3
"""
Run all-headers sampling experiments across workloads and schemes
"""

import os
import sys
import subprocess
import argparse
import json
from pathlib import Path

SCHEMES = [
    "HEADER_HASH",
    "HEADER_PAGE_HASH",
    "HEADER_POISSON_BYTES",
    "HEADER_HYBRID",
]

WORKLOADS = [
    "monotonic",
    "high-reuse",
    "curl",
    "memcached",
    "nginx",
]

DEFAULT_HASH_MASK = "0xFF"
DEFAULT_POISSON_MEAN = "4096"

def run_experiment(workload, scheme, run_num, base_dir, workload_script):
    """Run a single experiment"""
    output_dir = base_dir / "raw" / workload / scheme
    output_dir.mkdir(parents=True, exist_ok=True)
    
    stats_file = output_dir / f"run_{run_num}.json"
    
    env = os.environ.copy()
    env["SAMPLER_SCHEME"] = scheme
    env["SAMPLER_STATS_FILE"] = str(stats_file)
    env["SAMPLER_LIB"] = str(base_dir / "libsampler_all_headers.so")
    
    if "HASH" in scheme:
        env["SAMPLER_HASH_MASK"] = DEFAULT_HASH_MASK
    if "POISSON" in scheme or "HYBRID" in scheme:
        env["SAMPLER_POISSON_MEAN_BYTES"] = DEFAULT_POISSON_MEAN
    
    if workload in ["monotonic", "high-reuse"]:
        env["WORKLOAD_N"] = "10000" if workload == "monotonic" else "1000"
        if workload == "high-reuse":
            env["WORKLOAD_SLOTS"] = "100"
            env["WORKLOAD_ITERATIONS"] = "10000"
    
    print(f"  Run {run_num}: {workload} with {scheme}...")
    
    try:
        result = subprocess.run(
            [workload_script, workload, scheme, str(stats_file)],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=600
        )
        
        if not stats_file.exists():
            print(f"    WARNING: Stats file not created")
            return False
        
        try:
            with open(stats_file) as f:
                json.load(f)
        except json.JSONDecodeError:
            print(f"    WARNING: Invalid JSON")
            return False
        
        print(f"    ✓ Success")
        return True
    except subprocess.TimeoutExpired:
        print(f"    ✗ TIMEOUT")
        return False
    except Exception as e:
        print(f"    ✗ ERROR: {e}")
        return False

def main():
    parser = argparse.ArgumentParser(description="Run all-headers sampling experiments")
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--schemes", nargs="+", choices=SCHEMES, default=SCHEMES)
    parser.add_argument("--workloads", nargs="+", choices=WORKLOADS, default=WORKLOADS)
    parser.add_argument("--skip-real-world", action="store_true")
    
    args = parser.parse_args()
    
    script_dir = Path(__file__).parent.absolute()
    repo_root = script_dir.parent.parent.parent
    workload_script = repo_root / "benchmark-results" / "workloads" / "run_workload.sh"
    
    if not workload_script.exists():
        print(f"ERROR: Workload script not found: {workload_script}")
        return 1
    
    lib_path = script_dir / "libsampler_all_headers.so"
    if not lib_path.exists():
        print(f"ERROR: Library not found: {lib_path}")
        print("Run 'make' first")
        return 1
    
    workloads = args.workloads
    if args.skip_real_world:
        workloads = [w for w in workloads if w in ["monotonic", "high-reuse"]]
    
    print("="*60)
    print("All-Headers Sampling Experiments")
    print("="*60)
    print(f"Schemes: {', '.join(args.schemes)}")
    print(f"Workloads: {', '.join(workloads)}")
    print(f"Runs per pair: {args.runs}")
    print(f"Total: {len(args.schemes) * len(workloads) * args.runs}")
    print("="*60)
    print()
    
    total = 0
    successful = 0
    
    for scheme in args.schemes:
        for workload in workloads:
            print(f"\n[{scheme}] {workload.upper()}")
            for run_num in range(1, args.runs + 1):
                total += 1
                if run_experiment(workload, scheme, run_num, script_dir, workload_script):
                    successful += 1
    
    print()
    print("="*60)
    print(f"Results: {successful}/{total} successful")
    print("="*60)
    
    if successful < total:
        print(f"\nWARNING: {total - successful} failed")
        return 1
    
    print("\nNext steps:")
    print("  1. python3 aggregate_all_headers_results.py")
    print("  2. python3 make_plots.py")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
