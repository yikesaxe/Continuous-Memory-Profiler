#!/usr/bin/env python3
"""
Generate plots from all-headers results
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

def plot_sample_rate_allocs(data, workload, output_file, title_suffix=""):
    schemes = sorted(data[workload].keys())
    means = [data[workload][s]["sample_rate_allocs"]["mean"] for s in schemes]
    stds = [data[workload][s]["sample_rate_allocs"]["std"] for s in schemes]
    
    fig, ax = plt.subplots(figsize=(10, 6))
    x = np.arange(len(schemes))
    ax.bar(x, means, yerr=stds, capsize=5, alpha=0.7, color='steelblue')
    ax.axhline(y=0.00390625, color='red', linestyle='--', linewidth=2, label='Target: 1/256')
    
    ax.set_xlabel('Sampling Scheme', fontsize=12)
    ax.set_ylabel('Sample Rate (allocations)', fontsize=12)
    ax.set_title(f'{workload.title()}: Sample Rate {title_suffix}', fontsize=14, fontweight='bold')
    ax.set_xticks(x)
    ax.set_xticklabels([s.replace('HEADER_', '') for s in schemes], rotation=15, ha='right')
    ax.legend()
    ax.grid(axis='y', alpha=0.3)
    
    plt.tight_layout()
    plt.savefig(output_file, dpi=300)
    plt.close()
    print(f"✓ Created: {output_file}")

def plot_sample_rate_bytes(data, workload, output_file):
    schemes = sorted(data[workload].keys())
    means = [data[workload][s]["sample_rate_bytes"]["mean"] for s in schemes]
    stds = [data[workload][s]["sample_rate_bytes"]["std"] for s in schemes]
    
    fig, ax = plt.subplots(figsize=(10, 6))
    x = np.arange(len(schemes))
    ax.bar(x, means, yerr=stds, capsize=5, alpha=0.7, color='coral')
    
    ax.set_xlabel('Sampling Scheme', fontsize=12)
    ax.set_ylabel('Sample Rate (bytes)', fontsize=12)
    ax.set_title(f'{workload.title()}: Byte Sampling Rate (All-Headers)', fontsize=14, fontweight='bold')
    ax.set_xticks(x)
    ax.set_xticklabels([s.replace('HEADER_', '') for s in schemes], rotation=15, ha='right')
    ax.grid(axis='y', alpha=0.3)
    
    plt.tight_layout()
    plt.savefig(output_file, dpi=300)
    plt.close()
    print(f"✓ Created: {output_file}")

def plot_page_hash_coverage(data, output_file):
    """Plot page coverage for PAGE_HASH schemes"""
    workloads = [w for w in sorted(data.keys()) if any("PAGE" in s for s in data[w].keys())]
    
    if not workloads:
        print("  No PAGE_HASH data found")
        return
    
    fig, ax = plt.subplots(figsize=(10, 6))
    
    workload_data = []
    labels = []
    
    for workload in workloads:
        for scheme in sorted(data[workload].keys()):
            if "PAGE" in scheme and "page_coverage" in data[workload][scheme]:
                pc = data[workload][scheme]["page_coverage"]["mean"]
                up = data[workload][scheme]["approx_unique_pages"]["mean"]
                sp = data[workload][scheme]["approx_sampled_pages"]["mean"]
                
                workload_data.append((workload, pc, up, sp))
                labels.append(f"{workload}\n({int(up)} pages)")
    
    if not workload_data:
        print("  No page coverage data")
        return
    
    x = np.arange(len(workload_data))
    coverages = [d[1] for d in workload_data]
    
    bars = ax.bar(x, coverages, alpha=0.7, color='indianred')
    
    ax.set_xlabel('Workload', fontsize=12)
    ax.set_ylabel('Page Coverage (sampled/unique)', fontsize=12)
    ax.set_title('PAGE_HASH: Page Coverage by Workload', fontsize=14, fontweight='bold')
    ax.set_xticks(x)
    ax.set_xticklabels(labels, fontsize=10)
    ax.set_ylim(0, max(coverages) * 1.2 if coverages else 1)
    ax.grid(axis='y', alpha=0.3)
    
    for i, (wl, pc, up, sp) in enumerate(workload_data):
        ax.text(i, pc + 0.01, f'{sp:.0f}/{up:.0f}', ha='center', fontsize=9)
    
    plt.tight_layout()
    plt.savefig(output_file, dpi=300)
    plt.close()
    print(f"✓ Created: {output_file}")

def plot_comparison_across_workloads(data, output_file):
    """Multi-workload comparison"""
    workloads = sorted(data.keys())
    schemes = sorted(set(s for w in data.values() for s in w.keys()))
    
    fig, axes = plt.subplots(1, min(len(workloads), 4), figsize=(5*min(len(workloads), 4), 6), sharey=True)
    if len(workloads) == 1:
        axes = [axes]
    
    for ax, workload in zip(axes, workloads[:4]):
        means = [data[workload].get(s, {}).get("sample_rate_allocs", {}).get("mean", 0) for s in schemes]
        
        x = np.arange(len(schemes))
        ax.bar(x, means, alpha=0.7, color='steelblue')
        ax.axhline(y=0.00390625, color='red', linestyle='--', linewidth=2)
        ax.set_title(workload.title(), fontsize=12, fontweight='bold')
        ax.set_xticks(x)
        ax.set_xticklabels([s.replace('HEADER_', '').replace('_', '\n') for s in schemes], fontsize=8)
        ax.grid(axis='y', alpha=0.3)
    
    axes[0].set_ylabel('Sample Rate (allocations)', fontsize=12)
    plt.suptitle('All-Headers: Sample Rate Comparison', fontsize=14, fontweight='bold')
    plt.tight_layout()
    plt.savefig(output_file, dpi=300)
    plt.close()
    print(f"✓ Created: {output_file}")

def main():
    script_dir = Path(__file__).parent.absolute()
    summary_file = script_dir / "all_headers_results_summary.json"
    plots_dir = script_dir / "plots"
    
    print("="*60)
    print("Generating All-Headers Plots")
    print("="*60)
    
    print(f"\nLoading: {summary_file}")
    data = load_summary(summary_file)
    
    if not data:
        print("ERROR: No data")
        return 1
    
    plots_dir.mkdir(exist_ok=True)
    
    print("\nGenerating plots...")
    
    if "monotonic" in data:
        plot_sample_rate_allocs(data, "monotonic", 
                                plots_dir / "mono_all_headers_sample_rate_allocs.png",
                                "(All-Headers)")
    
    if "high-reuse" in data:
        plot_sample_rate_allocs(data, "high-reuse", 
                                plots_dir / "reuse_all_headers_sample_rate_allocs.png",
                                "(All-Headers)")
    
    if "curl" in data:
        plot_sample_rate_bytes(data, "curl", 
                              plots_dir / "curl_all_headers_sample_rate_bytes.png")
    
    if "memcached" in data:
        plot_sample_rate_allocs(data, "memcached",
                               plots_dir / "memcached_all_headers_sample_rate_allocs.png")
    
    if "nginx" in data:
        plot_sample_rate_allocs(data, "nginx",
                               plots_dir / "nginx_all_headers_sample_rate_allocs.png")
    
    # PAGE_HASH specific
    plot_page_hash_coverage(data, plots_dir / "page_hash_page_coverage_all_headers.png")
    
    # Cross-workload
    plot_comparison_across_workloads(data, plots_dir / "all_workloads_comparison_all_headers.png")
    
    print("\n" + "="*60)
    print(f"✓ Plots saved to: {plots_dir}")
    print("="*60)
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
