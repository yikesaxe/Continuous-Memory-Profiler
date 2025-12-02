#!/usr/bin/env python3
"""
Generate plots from sample-headers results
"""

import json
import sys
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

def load_summary(summary_file):
    try:
        with open(summary_file) as f:
            return json.load(f)
    except Exception as e:
        print(f"ERROR: {e}")
        return None

def plot_sample_rate_allocs(data, output_file):
    """Bar chart comparing all schemes across workloads"""
    workloads = sorted(data.keys())
    schemes = sorted(set(s for w in data.values() for s in w.keys()))
    
    fig, ax = plt.subplots(figsize=(12, 6))
    
    x = np.arange(len(workloads))
    width = 0.25
    
    for i, scheme in enumerate(schemes):
        means = [data[w].get(scheme, {}).get("sample_rate_allocs", {}).get("mean", 0) for w in workloads]
        stds = [data[w].get(scheme, {}).get("sample_rate_allocs", {}).get("std", 0) for w in workloads]
        ax.bar(x + i*width, means, width, yerr=stds, capsize=3, 
               label=scheme.replace('SAMPLE_HEADERS_', ''), alpha=0.7)
    
    ax.axhline(y=0.00390625, color='red', linestyle='--', linewidth=2, label='Target: 1/256', zorder=0)
    
    ax.set_xlabel('Workload', fontsize=12)
    ax.set_ylabel('Sample Rate (allocations)', fontsize=12)
    ax.set_title('Sample-Headers: Sample Rate Across Workloads', fontsize=14, fontweight='bold')
    ax.set_xticks(x + width * (len(schemes)-1) / 2)
    ax.set_xticklabels([w.title() for w in workloads])
    ax.legend(fontsize=9)
    ax.grid(axis='y', alpha=0.3)
    
    plt.tight_layout()
    plt.savefig(output_file, dpi=300)
    plt.close()
    print(f"✓ Created: {output_file}")

def plot_peak_map_size(data, output_file):
    """Bar chart of peak map size by workload"""
    workloads = sorted(data.keys())
    schemes = sorted(set(s for w in data.values() for s in w.keys()))
    
    fig, ax = plt.subplots(figsize=(12, 6))
    
    x = np.arange(len(workloads))
    width = 0.25
    
    for i, scheme in enumerate(schemes):
        means = [data[w].get(scheme, {}).get("map_peak_size", {}).get("mean", 0) for w in workloads]
        stds = [data[w].get(scheme, {}).get("map_peak_size", {}).get("std", 0) for w in workloads]
        ax.bar(x + i*width, means, width, yerr=stds, capsize=3,
               label=scheme.replace('SAMPLE_HEADERS_', ''), alpha=0.7)
    
    ax.set_xlabel('Workload', fontsize=12)
    ax.set_ylabel('Peak Map Size (live sampled allocs)', fontsize=12)
    ax.set_title('Sample-Headers: Peak Hash Table Size', fontsize=14, fontweight='bold')
    ax.set_xticks(x + width * (len(schemes)-1) / 2)
    ax.set_xticklabels([w.title() for w in workloads])
    ax.legend(fontsize=9)
    ax.grid(axis='y', alpha=0.3)
    
    plt.tight_layout()
    plt.savefig(output_file, dpi=300)
    plt.close()
    print(f"✓ Created: {output_file}")

def plot_map_ops_overhead(data, output_file):
    """Map operations per 1000 allocations"""
    workloads = sorted(data.keys())
    schemes = sorted(set(s for w in data.values() for s in w.keys()))
    
    fig, ax = plt.subplots(figsize=(12, 6))
    
    x = np.arange(len(workloads))
    width = 0.25
    
    for i, scheme in enumerate(schemes):
        means = [data[w].get(scheme, {}).get("map_ops_per_1k_allocs", {}).get("mean", 0) for w in workloads]
        ax.bar(x + i*width, means, width, 
               label=scheme.replace('SAMPLE_HEADERS_', ''), alpha=0.7)
    
    ax.set_xlabel('Workload', fontsize=12)
    ax.set_ylabel('Map Operations per 1000 Allocations', fontsize=12)
    ax.set_title('Sample-Headers: Hash Table Operation Overhead', fontsize=14, fontweight='bold')
    ax.set_xticks(x + width * (len(schemes)-1) / 2)
    ax.set_xticklabels([w.title() for w in workloads])
    ax.legend(fontsize=9)
    ax.grid(axis='y', alpha=0.3)
    
    plt.tight_layout()
    plt.savefig(output_file, dpi=300)
    plt.close()
    print(f"✓ Created: {output_file}")

def plot_memory_overhead_comparison(data, output_file):
    """Compare memory overhead: headers vs map"""
    workloads = sorted(data.keys())
    schemes = sorted(set(s for w in data.values() for s in w.keys()))
    
    fig, axes = plt.subplots(1, 2, figsize=(14, 6))
    
    # Left: Header overhead (16 bytes per sampled alloc)
    ax = axes[0]
    x = np.arange(len(workloads))
    width = 0.25
    
    for i, scheme in enumerate(schemes):
        sampled_means = [data[w].get(scheme, {}).get("sampled_allocs", {}).get("mean", 0) for w in workloads]
        header_overhead = [s * 16 / 1024 for s in sampled_means]  # KB
        ax.bar(x + i*width, header_overhead, width,
               label=scheme.replace('SAMPLE_HEADERS_', ''), alpha=0.7)
    
    ax.set_xlabel('Workload', fontsize=11)
    ax.set_ylabel('Header Overhead (KB)', fontsize=11)
    ax.set_title('Header Memory Overhead (16 bytes × sampled)', fontsize=12, fontweight='bold')
    ax.set_xticks(x + width * (len(schemes)-1) / 2)
    ax.set_xticklabels([w.title() for w in workloads], fontsize=9)
    ax.legend(fontsize=8)
    ax.grid(axis='y', alpha=0.3)
    
    # Right: Map overhead estimate (~16 bytes per entry)
    ax = axes[1]
    for i, scheme in enumerate(schemes):
        peak_means = [data[w].get(scheme, {}).get("map_peak_size", {}).get("mean", 0) for w in workloads]
        map_overhead = [p * 16 / 1024 for p in peak_means]  # KB
        ax.bar(x + i*width, map_overhead, width,
               label=scheme.replace('SAMPLE_HEADERS_', ''), alpha=0.7)
    
    ax.set_xlabel('Workload', fontsize=11)
    ax.set_ylabel('Map Overhead (KB)', fontsize=11)
    ax.set_title('Hash Table Memory Overhead (est.)', fontsize=12, fontweight='bold')
    ax.set_xticks(x + width * (len(schemes)-1) / 2)
    ax.set_xticklabels([w.title() for w in workloads], fontsize=9)
    ax.legend(fontsize=8)
    ax.grid(axis='y', alpha=0.3)
    
    plt.suptitle('Sample-Headers: Memory Overhead Analysis', fontsize=14, fontweight='bold')
    plt.tight_layout()
    plt.savefig(output_file, dpi=300)
    plt.close()
    print(f"✓ Created: {output_file}")

def main():
    script_dir = Path(__file__).parent.absolute()
    summary_file = script_dir / "sample_headers_results_summary.json"
    plots_dir = script_dir / "plots"
    
    print("="*60)
    print("Generating Sample-Headers Plots")
    print("="*60)
    
    print(f"\nLoading: {summary_file}")
    data = load_summary(summary_file)
    
    if not data:
        print("ERROR: No data")
        return 1
    
    plots_dir.mkdir(exist_ok=True)
    
    print("\nGenerating plots...")
    
    plot_sample_rate_allocs(data, plots_dir / "sample_headers_sample_rate_allocs.png")
    plot_peak_map_size(data, plots_dir / "sample_headers_peak_map_size.png")
    plot_map_ops_overhead(data, plots_dir / "sample_headers_map_ops_overhead.png")
    plot_memory_overhead_comparison(data, plots_dir / "sample_headers_memory_overhead.png")
    
    print("\n" + "="*60)
    print(f"✓ Plots saved to: {plots_dir}")
    print("="*60)
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
