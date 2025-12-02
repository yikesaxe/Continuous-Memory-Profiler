#!/usr/bin/env python3
"""
Generate plots from aggregated stateless sampling results
"""

import json
import sys
from pathlib import Path
import matplotlib
matplotlib.use('Agg')  # Non-interactive backend
import matplotlib.pyplot as plt
import numpy as np

def load_summary(summary_file):
    """Load aggregated results"""
    try:
        with open(summary_file) as f:
            return json.load(f)
    except Exception as e:
        print(f"ERROR: Failed to load summary: {e}")
        return None

def plot_sample_rate_allocs(data, workload, output_file):
    """Bar chart of sample rate (allocs) for a workload across schemes"""
    schemes = sorted(data[workload].keys())
    means = [data[workload][s]["sample_rate_allocs"]["mean"] for s in schemes]
    stds = [data[workload][s]["sample_rate_allocs"]["std"] for s in schemes]
    
    fig, ax = plt.subplots(figsize=(10, 6))
    
    x = np.arange(len(schemes))
    bars = ax.bar(x, means, yerr=stds, capsize=5, alpha=0.7, color='steelblue')
    
    # Target line (1/256 = 0.00390625)
    ax.axhline(y=0.00390625, color='red', linestyle='--', linewidth=2, label='Target: 1/256')
    
    ax.set_xlabel('Sampling Scheme', fontsize=12)
    ax.set_ylabel('Sample Rate (allocations)', fontsize=12)
    ax.set_title(f'{workload.title()} Workload: Sample Rate by Scheme', fontsize=14, fontweight='bold')
    ax.set_xticks(x)
    ax.set_xticklabels([s.replace('STATELESS_', '') for s in schemes], rotation=15, ha='right')
    ax.legend()
    ax.grid(axis='y', alpha=0.3)
    
    plt.tight_layout()
    plt.savefig(output_file, dpi=300)
    plt.close()
    
    print(f"✓ Created plot: {output_file}")

def plot_sample_rate_bytes(data, workload, output_file):
    """Bar chart of sample rate (bytes) for a workload across schemes"""
    schemes = sorted(data[workload].keys())
    means = [data[workload][s]["sample_rate_bytes"]["mean"] for s in schemes]
    stds = [data[workload][s]["sample_rate_bytes"]["std"] for s in schemes]
    
    fig, ax = plt.subplots(figsize=(10, 6))
    
    x = np.arange(len(schemes))
    bars = ax.bar(x, means, yerr=stds, capsize=5, alpha=0.7, color='coral')
    
    ax.set_xlabel('Sampling Scheme', fontsize=12)
    ax.set_ylabel('Sample Rate (bytes)', fontsize=12)
    ax.set_title(f'{workload.title()} Workload: Byte Sampling Rate by Scheme', fontsize=14, fontweight='bold')
    ax.set_xticks(x)
    ax.set_xticklabels([s.replace('STATELESS_', '') for s in schemes], rotation=15, ha='right')
    ax.grid(axis='y', alpha=0.3)
    
    plt.tight_layout()
    plt.savefig(output_file, dpi=300)
    plt.close()
    
    print(f"✓ Created plot: {output_file}")

def plot_dead_zone_rates(data, workload, output_file):
    """Bar chart of dead zone rates for a workload"""
    schemes = sorted(data[workload].keys())
    means = [data[workload][s]["dead_zone_rate"]["mean"] for s in schemes]
    stds = [data[workload][s]["dead_zone_rate"]["std"] for s in schemes]
    
    fig, ax = plt.subplots(figsize=(10, 6))
    
    x = np.arange(len(schemes))
    bars = ax.bar(x, means, yerr=stds, capsize=5, alpha=0.7, color='indianred')
    
    ax.set_xlabel('Sampling Scheme', fontsize=12)
    ax.set_ylabel('Dead Zone Rate', fontsize=12)
    ax.set_title(f'{workload.title()} Workload: Dead Zones (100k alloc windows with 0 samples)', 
                 fontsize=14, fontweight='bold')
    ax.set_xticks(x)
    ax.set_xticklabels([s.replace('STATELESS_', '') for s in schemes], rotation=15, ha='right')
    ax.grid(axis='y', alpha=0.3)
    
    plt.tight_layout()
    plt.savefig(output_file, dpi=300)
    plt.close()
    
    print(f"✓ Created plot: {output_file}")

def plot_scheme_comparison(data, output_file):
    """Multi-workload comparison across schemes"""
    workloads = sorted(data.keys())
    schemes = sorted(set(s for w in data.values() for s in w.keys()))
    
    fig, axes = plt.subplots(1, len(workloads), figsize=(5*len(workloads), 6), sharey=True)
    if len(workloads) == 1:
        axes = [axes]
    
    for ax, workload in zip(axes, workloads):
        means = [data[workload].get(s, {}).get("sample_rate_allocs", {}).get("mean", 0) 
                 for s in schemes]
        
        x = np.arange(len(schemes))
        ax.bar(x, means, alpha=0.7, color='steelblue')
        ax.axhline(y=0.00390625, color='red', linestyle='--', linewidth=2)
        ax.set_title(workload.title(), fontsize=12, fontweight='bold')
        ax.set_xticks(x)
        ax.set_xticklabels([s.replace('STATELESS_', '').replace('_', '\n') for s in schemes], 
                           fontsize=8)
        ax.grid(axis='y', alpha=0.3)
    
    axes[0].set_ylabel('Sample Rate (allocations)', fontsize=12)
    plt.suptitle('Sample Rate Comparison Across Workloads', fontsize=14, fontweight='bold')
    plt.tight_layout()
    plt.savefig(output_file, dpi=300)
    plt.close()
    
    print(f"✓ Created plot: {output_file}")

def main():
    script_dir = Path(__file__).parent.absolute()
    summary_file = script_dir / "stateless_results_summary.json"
    plots_dir = script_dir / "plots"
    
    print("="*60)
    print("Generating Plots from Stateless Sampling Results")
    print("="*60)
    
    # Load data
    print(f"\nLoading summary: {summary_file}")
    data = load_summary(summary_file)
    
    if data is None or not data:
        print("ERROR: No data found")
        return 1
    
    plots_dir.mkdir(exist_ok=True)
    
    # Generate plots
    print("\nGenerating plots...")
    
    # Per-workload plots
    if "monotonic" in data:
        plot_sample_rate_allocs(data, "monotonic", 
                                plots_dir / "mono_sample_rate_allocs_stateless.png")
        plot_dead_zone_rates(data, "monotonic",
                            plots_dir / "mono_dead_zones_stateless.png")
    
    if "high-reuse" in data:
        plot_sample_rate_allocs(data, "high-reuse", 
                                plots_dir / "reuse_sample_rate_allocs_stateless.png")
        plot_dead_zone_rates(data, "high-reuse",
                            plots_dir / "reuse_dead_zones_stateless.png")
    
    if "curl" in data:
        plot_sample_rate_bytes(data, "curl", 
                              plots_dir / "curl_sample_rate_bytes_stateless.png")
    
    if "memcached" in data:
        plot_sample_rate_allocs(data, "memcached",
                               plots_dir / "memcached_sample_rate_allocs_stateless.png")
    
    if "nginx" in data:
        plot_sample_rate_allocs(data, "nginx",
                               plots_dir / "nginx_sample_rate_allocs_stateless.png")
    
    # Cross-workload comparison
    plot_scheme_comparison(data, plots_dir / "all_workloads_comparison.png")
    
    print("\n" + "="*60)
    print(f"✓ Plots saved to: {plots_dir}")
    print("="*60)
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
