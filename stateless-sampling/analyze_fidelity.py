#!/usr/bin/env python3
"""
Live Heap Fidelity Analysis

Compares ground truth live heap (all allocations) vs sampled live heap (weighted samples)
to measure sampling accuracy.

Usage:
    python3 analyze_fidelity.py <logfile> [--bins N] [--output-dir DIR]
"""

import sys
import argparse
from collections import defaultdict, Counter
import matplotlib.pyplot as plt
import numpy as np
from pathlib import Path


class HeapProfile:
    """Tracks live allocations and computes statistics."""
    
    def __init__(self, name):
        self.name = name
        self.live = {}  # addr -> size
        self.snapshots = []  # List of (event_idx, total_bytes, allocation_count, size_histogram)
        
    def malloc(self, addr, size):
        """Record an allocation."""
        if size > 0:  # Only track if size is reported
            self.live[addr] = size
    
    def free(self, addr):
        """Record a deallocation."""
        self.live.pop(addr, None)
    
    def take_snapshot(self, event_idx):
        """Capture current heap state."""
        total_bytes = sum(self.live.values())
        alloc_count = len(self.live)
        
        # Create size histogram (log2 bins)
        size_hist = defaultdict(int)
        for size in self.live.values():
            if size > 0:
                bin_idx = int(np.log2(size))
                size_hist[bin_idx] += 1
        
        self.snapshots.append({
            'event_idx': event_idx,
            'total_bytes': total_bytes,
            'alloc_count': alloc_count,
            'size_histogram': dict(size_hist)
        })
        
        return total_bytes, alloc_count


def parse_log(logfile):
    """
    Parse CSV log file with format:
    MALLOC, timestamp, address, size
    FREE, timestamp, address, -1
    
    Returns sorted list of (timestamp, event_type, address, size)
    """
    events = []
    
    with open(logfile) as f:
        for line_no, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
                
            parts = [x.strip() for x in line.split(",")]
            if len(parts) != 4:
                print(f"Warning: Skipping malformed line {line_no}: {line}", file=sys.stderr)
                continue
            
            try:
                event_type, ts_str, addr, size_str = parts
                timestamp = float(ts_str)
                size = int(size_str)
                events.append((timestamp, event_type, addr, size))
            except ValueError as e:
                print(f"Warning: Line {line_no} parse error: {e}", file=sys.stderr)
                continue
    
    # Sort by timestamp
    events.sort(key=lambda x: x[0])
    print(f"Parsed {len(events)} events from {logfile}")
    
    return events


def analyze_logs(events, num_snapshots=20):
    """
    Process events and build ground truth + sampled heap profiles.
    
    Returns:
        ground_truth: HeapProfile with all allocations
        sampled: HeapProfile with only sampled allocations (weighted)
    """
    ground_truth = HeapProfile("Ground Truth")
    sampled = HeapProfile("Sampled")
    
    # Determine snapshot intervals
    total_events = len(events)
    snapshot_interval = max(1, total_events // num_snapshots)
    
    print(f"\nProcessing {total_events} events with snapshots every {snapshot_interval} events...")
    
    for idx, (timestamp, event_type, addr, size) in enumerate(events, 1):
        if event_type == "MALLOC":
            # Ground truth: track actual size (would need to be logged separately)
            # For now, we'll track reported_size as proxy
            # TODO: Log actual_size separately in sampler.c
            ground_truth.malloc(addr, abs(size))
            
            # Sampled: only track if size > 0 (means it was sampled)
            if size > 0:
                sampled.malloc(addr, size)
                
        elif event_type == "FREE":
            ground_truth.free(addr)
            sampled.free(addr)
        
        # Take snapshot at intervals
        if idx % snapshot_interval == 0 or idx == total_events:
            gt_bytes, gt_count = ground_truth.take_snapshot(idx)
            s_bytes, s_count = sampled.take_snapshot(idx)
            
            print(f"  Snapshot @ event {idx:8d}: "
                  f"GT={gt_bytes:12,} bytes ({gt_count:6,} allocs)  "
                  f"Sampled={s_bytes:12,} bytes ({s_count:6,} allocs)")
    
    return ground_truth, sampled


def plot_live_heap_comparison(ground_truth, sampled, output_dir):
    """Create comparison plots of live heap over time."""
    
    output_dir = Path(output_dir)
    output_dir.mkdir(exist_ok=True, parents=True)
    
    # Extract data
    gt_events = [s['event_idx'] for s in ground_truth.snapshots]
    gt_bytes = [s['total_bytes'] for s in ground_truth.snapshots]
    gt_counts = [s['alloc_count'] for s in ground_truth.snapshots]
    
    s_events = [s['event_idx'] for s in sampled.snapshots]
    s_bytes = [s['total_bytes'] for s in sampled.snapshots]
    s_counts = [s['alloc_count'] for s in sampled.snapshots]
    
    # Plot 1: Total live bytes over time
    plt.figure(figsize=(14, 6))
    plt.plot(gt_events, gt_bytes, 'b-', linewidth=2, label='Ground Truth', alpha=0.7)
    plt.plot(s_events, s_bytes, 'r--', linewidth=2, label='Sampled (Weighted)', alpha=0.7)
    plt.xlabel('Event Index')
    plt.ylabel('Total Live Bytes')
    plt.title('Live Heap Size: Ground Truth vs Sampled')
    plt.legend()
    plt.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(output_dir / 'live_heap_bytes.png', dpi=300)
    plt.close()
    print(f"Saved: {output_dir / 'live_heap_bytes.png'}")
    
    # Plot 2: Number of live allocations over time
    plt.figure(figsize=(14, 6))
    plt.plot(gt_events, gt_counts, 'b-', linewidth=2, label='Ground Truth', alpha=0.7)
    plt.plot(s_events, s_counts, 'r--', linewidth=2, label='Sampled', alpha=0.7)
    plt.xlabel('Event Index')
    plt.ylabel('Number of Live Allocations')
    plt.title('Live Allocation Count: Ground Truth vs Sampled')
    plt.legend()
    plt.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(output_dir / 'live_heap_count.png', dpi=300)
    plt.close()
    print(f"Saved: {output_dir / 'live_heap_count.png'}")
    
    # Plot 3: Relative error over time
    plt.figure(figsize=(14, 6))
    relative_errors = []
    for gt_b, s_b in zip(gt_bytes, s_bytes):
        if gt_b > 0:
            rel_err = abs(s_b - gt_b) / gt_b * 100
            relative_errors.append(rel_err)
        else:
            relative_errors.append(0)
    
    plt.plot(gt_events, relative_errors, 'g-', linewidth=2, alpha=0.7)
    plt.xlabel('Event Index')
    plt.ylabel('Relative Error (%)')
    plt.title('Sampling Fidelity: |Sampled - Ground Truth| / Ground Truth × 100%')
    plt.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(output_dir / 'relative_error.png', dpi=300)
    plt.close()
    print(f"Saved: {output_dir / 'relative_error.png'}")


def plot_size_histograms(ground_truth, sampled, output_dir, snapshot_indices=None):
    """
    Plot allocation size histograms at specific snapshots.
    
    Args:
        snapshot_indices: List of snapshot indices to plot (default: first, middle, last)
    """
    output_dir = Path(output_dir)
    
    if snapshot_indices is None:
        n = len(ground_truth.snapshots)
        if n >= 3:
            snapshot_indices = [0, n // 2, n - 1]
        else:
            snapshot_indices = list(range(n))
    
    for snap_idx in snapshot_indices:
        if snap_idx >= len(ground_truth.snapshots):
            continue
            
        gt_snap = ground_truth.snapshots[snap_idx]
        s_snap = sampled.snapshots[snap_idx]
        
        event_idx = gt_snap['event_idx']
        
        # Prepare histogram data (log2 bins)
        gt_hist = gt_snap['size_histogram']
        s_hist = s_snap['size_histogram']
        
        all_bins = sorted(set(gt_hist.keys()) | set(s_hist.keys()))
        
        if not all_bins:
            continue
        
        bin_labels = [f"2^{b}" if b < 10 else f"{1<<b}" for b in all_bins]
        gt_counts = [gt_hist.get(b, 0) for b in all_bins]
        s_counts = [s_hist.get(b, 0) for b in all_bins]
        
        # Plot grouped bars
        x = np.arange(len(all_bins))
        width = 0.35
        
        fig, ax = plt.subplots(figsize=(14, 6))
        ax.bar(x - width/2, gt_counts, width, label='Ground Truth', alpha=0.7, color='blue')
        ax.bar(x + width/2, s_counts, width, label='Sampled', alpha=0.7, color='red')
        
        ax.set_xlabel('Allocation Size (bytes)')
        ax.set_ylabel('Number of Live Allocations')
        ax.set_title(f'Allocation Size Distribution @ Event {event_idx}')
        ax.set_xticks(x)
        ax.set_xticklabels(bin_labels, rotation=45, ha='right')
        ax.legend()
        ax.grid(True, axis='y', alpha=0.3)
        
        plt.tight_layout()
        filename = output_dir / f'size_histogram_event_{event_idx}.png'
        plt.savefig(filename, dpi=300)
        plt.close()
        print(f"Saved: {filename}")


def print_statistics(ground_truth, sampled):
    """Print summary statistics comparing ground truth vs sampled."""
    
    print("\n" + "="*80)
    print("FIDELITY STATISTICS")
    print("="*80)
    
    # Overall statistics across all snapshots
    gt_total_bytes = [s['total_bytes'] for s in ground_truth.snapshots]
    s_total_bytes = [s['total_bytes'] for s in sampled.snapshots]
    
    gt_counts = [s['alloc_count'] for s in ground_truth.snapshots]
    s_counts = [s['alloc_count'] for s in sampled.snapshots]
    
    # Compute relative errors
    byte_errors = []
    count_errors = []
    
    for gt_b, s_b, gt_c, s_c in zip(gt_total_bytes, s_total_bytes, gt_counts, s_counts):
        if gt_b > 0:
            byte_errors.append(abs(s_b - gt_b) / gt_b * 100)
        if gt_c > 0:
            count_errors.append(abs(s_c - gt_c) / gt_c * 100)
    
    print(f"\nGround Truth Live Heap:")
    print(f"  Avg bytes:       {np.mean(gt_total_bytes):,.0f}")
    print(f"  Max bytes:       {np.max(gt_total_bytes):,.0f}")
    print(f"  Avg alloc count: {np.mean(gt_counts):,.0f}")
    print(f"  Max alloc count: {np.max(gt_counts):,.0f}")
    
    print(f"\nSampled Live Heap (Weighted):")
    print(f"  Avg bytes:       {np.mean(s_total_bytes):,.0f}")
    print(f"  Max bytes:       {np.max(s_total_bytes):,.0f}")
    print(f"  Avg alloc count: {np.mean(s_counts):,.0f}")
    print(f"  Max alloc count: {np.max(s_counts):,.0f}")
    
    print(f"\nSampling Fidelity:")
    print(f"  Byte estimate - Mean relative error:   {np.mean(byte_errors):6.2f}%")
    print(f"  Byte estimate - Median relative error: {np.median(byte_errors):6.2f}%")
    print(f"  Byte estimate - Max relative error:    {np.max(byte_errors):6.2f}%")
    print(f"  Byte estimate - Min relative error:    {np.min(byte_errors):6.2f}%")
    
    print(f"\n  Count estimate - Mean relative error:   {np.mean(count_errors):6.2f}%")
    print(f"  Count estimate - Median relative error: {np.median(count_errors):6.2f}%")
    
    # Sampling rate
    final_gt_count = gt_counts[-1] if gt_counts else 0
    final_s_count = s_counts[-1] if s_counts else 0
    
    if final_gt_count > 0:
        sample_rate = final_s_count / final_gt_count * 100
        print(f"\n  Final sampling rate (count): {sample_rate:.4f}%")
    
    print("="*80 + "\n")


def main():
    parser = argparse.ArgumentParser(
        description='Analyze live heap fidelity from sampler logs',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Example:
    python3 analyze_fidelity.py malloc_log.csv --bins 20 --output-dir results/
        """
    )
    parser.add_argument('logfile', help='CSV log file from sampler')
    parser.add_argument('--bins', type=int, default=20, 
                        help='Number of snapshot bins (default: 20)')
    parser.add_argument('--output-dir', default='fidelity_analysis',
                        help='Output directory for plots (default: fidelity_analysis)')
    
    args = parser.parse_args()
    
    # Parse events
    events = parse_log(args.logfile)
    
    if not events:
        print("Error: No events found in log file", file=sys.stderr)
        return 1
    
    # Analyze
    ground_truth, sampled = analyze_logs(events, num_snapshots=args.bins)
    
    # Generate plots
    print("\nGenerating plots...")
    plot_live_heap_comparison(ground_truth, sampled, args.output_dir)
    plot_size_histograms(ground_truth, sampled, args.output_dir)
    
    # Print statistics
    print_statistics(ground_truth, sampled)
    
    print(f"\n✓ Analysis complete! Results saved to {args.output_dir}/")
    
    return 0


if __name__ == '__main__':
    sys.exit(main())

