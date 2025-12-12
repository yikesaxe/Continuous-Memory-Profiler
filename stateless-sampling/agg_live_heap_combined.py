#!/usr/bin/env python3
"""
Aggregate and visualize combined sampling logs where both Poisson and Stateless Hash
are evaluated on every allocation.

Log format (8 columns):
  MALLOC, timestamp, address, actual_size, poisson_tracked, poisson_size, hash_tracked, hash_size
  FREE, timestamp, address, -1, poisson_tracked, -1, hash_tracked, -1

Generates overlaid histograms comparing:
  - Ground truth (all allocations)
  - Poisson sampling estimates
  - Stateless Hash estimates
"""

import sys
import os
from collections import defaultdict
import matplotlib.pyplot as plt

def process_combined_file(path, num_bins):
    """Parse combined log and generate overlaid histograms."""
    
    # ---- 1. READ AND PARSE ----
    malloc_count = 0
    malloc_count_hash = 0
    malloc_addresses = set()
    malloc_addresses_hash = set()

    free_count = 0
    free_count_hash = 0
    free_addresses = set()
    free_addresses_hash = set()

    avg_size_hash_malloc = []
    avg_size_hash_free = []

    size_freq_hash_malloc = defaultdict(int)
    size_freq_hash_free = defaultdict(int)

    records = []
    with open(path) as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            
            parts = [x.strip() for x in line.split(",")]
            
            # Handle START/END markers (4 columns)
            if len(parts) == 4 and parts[0] in ["START", "END"]:
                op = parts[0]
                ts = float(parts[1])
                records.append((op, ts, None, -1, 0, 0, 0, 0))
                continue
            
            # Must be 8 columns for MALLOC/FREE
            if len(parts) != 8:
                print(f"Error on line {line_num}: Expected 8 fields, got {len(parts)}", file=sys.stderr)
                print(f"Line: {line}", file=sys.stderr)
                continue
            
            try:
                op, ts, addr, actual_size, pois_tracked, pois_size, hash_tracked, hash_size = parts
                ts = float(ts)
                actual_size = int(actual_size)
                pois_tracked = int(pois_tracked)
                pois_size = int(pois_size)
                hash_tracked = int(hash_tracked)
                hash_size = int(hash_size)
            except ValueError as e:
                print(f"Parse error on line {line_num}: {e}", file=sys.stderr)
                print(f"Line: {line}", file=sys.stderr)
                continue
            
            records.append((op, ts, addr, actual_size, pois_tracked, pois_size, hash_tracked, hash_size))
    
    if not records:
        print("No valid records found", file=sys.stderr)
        return
    
    # Sort by timestamp
    records.sort(key=lambda x: x[1])
    total_rows = len(records)
    
    print(f"Parsed {total_rows} records")
    
    # ---- 2. DETERMINE TIME-BASED BIN BOUNDARIES FROM START/END MARKERS ----
    # Find START and END markers
    start_time = None
    end_time = None
    
    for op, ts, addr, size, _, _, _, _ in records:
        if op == "START":
            start_time = ts
        elif op == "END":
            end_time = ts
    
    if start_time is None or end_time is None:
        print("Warning: Missing START or END marker, using first and last timestamps", file=sys.stderr)
        all_timestamps = [ts for op, ts, _, _, _, _, _, _ in records if op not in ["START", "END"]]
        start_time = min(all_timestamps) if all_timestamps else 0
        end_time = max(all_timestamps) if all_timestamps else 0
    
    time_range = end_time - start_time
    
    print(f"Time range: {start_time:.3f} to {end_time:.3f} ({time_range:.3f} seconds)")
    
    if time_range <= 0:
        print("Warning: Zero time range", file=sys.stderr)
        num_bins = 1
        time_interval = 0
        time_boundaries = []
    else:
        # Create time boundaries (equal intervals)
        time_interval = time_range / num_bins
        time_boundaries = [start_time + (i + 1) * time_interval for i in range(num_bins)]
        
        print(f"Creating {num_bins} bins with {time_interval:.3f}s intervals")
        print(f"Time boundaries: {[f'{t:.3f}' for t in time_boundaries]}")
    
    # ---- 3. SIMULATE ALL THREE HEAPS ----
    # Ground truth: track all allocations
    live_truth = {}     # addr -> size
    # Poisson: track only sampled by Poisson
    live_poisson = {}   # addr -> reported size
    # Hash: track only sampled by Hash
    live_hash = {}      # addr -> reported size

    live_heap_by_time = defaultdict(dict)
    # Check for START/END markers
    has_start_marker = any(op == "START" for op, ts, addr, size, _, _, _, _ in records)
    started = not has_start_marker  # Auto-start if no marker
    
    if not has_start_marker:
        print("Note: No START marker found, processing all records", file=sys.stderr)
    
    # Track which time boundaries we've crossed
    next_boundary_idx = 0
    
    for idx, (op, ts, addr, actual_size, pois_tracked, pois_size, hash_tracked, hash_size) in enumerate(records, start=1):
        # Handle START/END markers
        if op == "START":
            started = True
            continue
        if op == "END":
            break
        if not started:
            continue
        
        if op == "MALLOC":
            # Ground truth: always track
            malloc_count += 1
            malloc_addresses.add(addr)
            live_truth[addr] = actual_size
            
            # Poisson: track if sampled
            if pois_tracked:
                live_poisson[addr] = pois_size
            
            # Hash: track if sampled
            if hash_tracked:
                size_freq_hash_malloc[hash_size] += 1
                malloc_addresses_hash.add(addr)
                malloc_count_hash += 1
                live_hash[addr] = hash_size
                avg_size_hash_malloc.append(hash_size)
        
        elif op == "FREE":
            # Remove from all heaps that were tracking it
            free_count += 1
            free_addresses.add(addr)
            live_truth.pop(addr, None)
            
            if pois_tracked:
                live_poisson.pop(addr, None)
            
            if hash_tracked:
                free_addresses_hash.add(addr)
                free_count_hash += 1
                hash_size = live_hash.pop(addr, None)
                avg_size_hash_free.append(hash_size)
                size_freq_hash_free[hash_size] += 1

        
        # Check if we've crossed a time boundary
        while next_boundary_idx < len(time_boundaries) and ts >= time_boundaries[next_boundary_idx]:
            boundary_time = time_boundaries[next_boundary_idx]
            elapsed = boundary_time - start_time

            # get the total size represented by eahc live heap at this time
            # store in our live_heap_by_time dict
            live_heap_by_time[elapsed] = {
                "truth": sum(live_truth.values()),
                "poisson": sum(live_poisson.values()),
                "hash": sum(live_hash.values())
            }

            print(f"time: {elapsed:.3f}s")

            print(f"Total mallocs: {malloc_count}")
            print(f"Total mallocs tracked by Hash: {malloc_count_hash}")
            print(f"Total unique addresses tracked: {len(malloc_addresses)}")
            print(f"Total unique addresses tracked by Hash: {len(malloc_addresses_hash)}")
            print(f"Ratio of mallocs tracked by Hash to total mallocs: {malloc_count_hash / malloc_count}")
            print(f"Ratio of unique addresses tracked by Hash to total addresses: {len(malloc_addresses_hash) / len(malloc_addresses)}")

            print(f"Total frees: {free_count}")
            print(f"Total frees tracked by Hash: {free_count_hash}")
            print(f"Total unique addresses freed: {len(free_addresses)}")
            print(f"Total unique addresses freed by Hash: {len(free_addresses_hash)}")
            print(f"Ratio of frees tracked by Hash to total frees: {free_count_hash / free_count}")
            print(f"Ratio of unique addresses freed by Hash to total addresses: {len(free_addresses_hash) / len(free_addresses)}")
            print(f"Average size of mallocs tracked by Hash: {sum(avg_size_hash_malloc) / len(avg_size_hash_malloc)}")
            print(f"Average size of frees tracked by Hash: {sum(avg_size_hash_free) / len(avg_size_hash_free)}")
            """
          @   print(f"\n=== BIN {next_boundary_idx + 1} T+{elapsed:.3f}s ===")
            print(f"Truth: {len(live_truth)} allocations, {sum(live_truth.values())} bytes")
            print(f"Poisson: {len(live_poisson)} tracked")
            print(f"Hash: {len(live_hash)} tracked")
            
            # # Use boundary index for filename
            # generate_overlaid_histogram(
            #     live_truth, live_poisson, live_hash,
            #     path, next_boundary_idx + 1, elapsed
            # )

            """
            next_boundary_idx += 1
    
    # Final histogram at end time
    elapsed_total = end_time - start_time
    live_heap_by_time[elapsed_total] = {
        "truth": sum(live_truth.values()),
        "poisson": sum(live_poisson.values()),
        "hash": sum(live_hash.values())
    }

    log_dir = os.path.dirname(path) or '.'
    log_base = os.path.basename(path).rsplit('.', 1)[0]

    # Generate bar chart with time on x-axis and total live heap size on y-axis
    times = sorted(live_heap_by_time.keys())
    truth_vals = [live_heap_by_time[t]["truth"] for t in times]
    poisson_vals = [live_heap_by_time[t]["poisson"] for t in times]
    hash_vals = [live_heap_by_time[t]["hash"] for t in times]
    
    # Create bar positions
    x = range(len(times))
    width = 0.25  # Width of bars
    
    plt.figure(figsize=(14, 7))
    plt.bar([i - width for i in x], truth_vals, width, label='Ground Truth', color='skyblue', alpha=0.8)
    plt.bar(x, poisson_vals, width, label='Poisson', color='coral', alpha=0.8)
    plt.bar([i + width for i in x], hash_vals, width, label='Stateless Hash', color='lightgreen', alpha=0.8)
    
    plt.xlabel('Time (seconds)', fontsize=12)
    plt.ylabel('Total Live Heap Size (bytes)', fontsize=12)
    plt.title('Live Heap Size Over Time', fontsize=14)
    plt.xticks(x, [f'{t:.2f}' for t in times], rotation=45)
    plt.legend(fontsize=11)
    plt.grid(True, axis='y', alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(log_dir, f"{log_base}_live_heap_over_time.png"), dpi=300)
    plt.close()

    # make the bars wider and dark colors
    # Convert to column chart: show only nonzero bars, x is discrete values with nonzero frequency.

    # Mallocs tracked by hash
    malloc_sizes = [size for size, freq in size_freq_hash_malloc.items() if freq > 0]
    malloc_freqs = [freq for size, freq in size_freq_hash_malloc.items() if freq > 0]
    plt.figure(figsize=(14, 7))
    
    # Use discrete positions instead of continuous x-axis
    x_positions = range(len(malloc_sizes))
    plt.bar(x_positions, malloc_freqs, width=0.8, 
            label='Size Frequency of Mallocs Tracked by Hash', 
            color='#145A32', alpha=1.0)

    # Set discrete labels
    plt.xticks(x_positions, [f'{size:,}' for size in malloc_sizes], 
            rotation=45, ha='right')
    plt.xlabel('Size (bytes)', fontsize=12)
    plt.ylabel('Frequency', fontsize=12)
    plt.title('Size Frequency of Mallocs Tracked by Hash (nonzero columns only)', fontsize=14)
    plt.legend(fontsize=11)
    plt.grid(True, axis='y', alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(log_dir, f"{log_base}_size_freq_hash_malloc.png"), dpi=300)
    plt.close()

    # Frees tracked by hash

    free_sizes = [size for size, freq in size_freq_hash_free.items() if freq > 0]
    free_freqs = [freq for size, freq in size_freq_hash_free.items() if freq > 0]
    plt.figure(figsize=(14, 7))
    x_positions = range(len(free_sizes))
    plt.bar(x_positions, free_freqs, width=0.8, 
            label='Size Frequency of Frees Tracked by Hash', 
            color='#145A32', alpha=1.0)

    # Set discrete labels
    plt.xticks(x_positions, [f'{size:,}' for size in free_sizes], 
            rotation=45, ha='right')
    plt.xlabel('Size (bytes)', fontsize=12)
    plt.ylabel('Frequency', fontsize=12)
    plt.title('Size Frequency of Frees Tracked by Hash (nonzero columns only)', fontsize=14)
    plt.legend(fontsize=11)
    plt.grid(True, axis='y', alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(log_dir, f"{log_base}_size_freq_hash_free.png"), dpi=300)
    plt.close()

    print(f"Total mallocs: {malloc_count}")
    print(f"Total mallocs tracked by Hash: {malloc_count_hash}")
    print(f"Total unique addresses tracked: {len(malloc_addresses)}")
    print(f"Total unique addresses tracked by Hash: {len(malloc_addresses_hash)}")
    print(f"Ratio of mallocs tracked by Hash to total mallocs: {malloc_count_hash / malloc_count}")
    print(f"Ratio of unique addresses tracked by Hash to total addresses: {len(malloc_addresses_hash) / len(malloc_addresses)}")

    print(f"Total frees: {free_count}")
    print(f"Total frees tracked by Hash: {free_count_hash}")
    print(f"Total unique addresses freed: {len(free_addresses)}")
    print(f"Total unique addresses freed by Hash: {len(free_addresses_hash)}")
    print(f"Ratio of frees tracked by Hash to total frees: {free_count_hash / free_count}")
    print(f"Ratio of unique addresses freed by Hash to total addresses: {len(free_addresses_hash) / len(free_addresses)}")

    """
    print(f"\n=== FINAL BIN @ T+{elapsed_total:.3f}s ===")
    print(f"Truth: {len(live_truth)} allocations, {sum(live_truth.values())} bytes")
    print(f"Poisson: {len(live_poisson)} tracked")
    print(f"Hash: {len(live_hash)} tracked")
    
    generate_overlaid_histogram(
        live_truth, live_poisson, live_hash,
        path, num_bins + 1, elapsed_total
    )
    """

def generate_overlaid_histogram(live_truth, live_poisson, live_hash, log_path, bin_num, elapsed_time):
    """Generate overlaid histogram showing all three sampling approaches."""
    
    log_dir = os.path.dirname(log_path) or '.'
    log_base = os.path.basename(log_path).rsplit('.', 1)[0]
    
    # Use elapsed time in filename for clarity
    filename_unweighted = os.path.join(log_dir, f"{log_base}_t{elapsed_time:.3f}s_overlay.png")
    filename_weighted = os.path.join(log_dir, f"{log_base}_t{elapsed_time:.3f}s_overlay_weighted.png")
    
    size_bin = 256
    
    # ---- BUILD HISTOGRAMS FOR EACH SCHEME ----
    
    # Ground truth: unweighted (just count allocations per size bin)
    bins_truth = defaultdict(int)
    for size in live_truth.values():
        b = (size // size_bin) * size_bin
        bins_truth[b] += 1
    
    # Poisson: unweighted and weighted
    bins_poisson_unweighted = defaultdict(int)
    bins_poisson_weighted = defaultdict(float)
    for size, weight in live_poisson.values():
        b = (size // size_bin) * size_bin
        bins_poisson_unweighted[b] += 1
        # Weight represents multiple allocations
        scale = weight / size if size > 0 else 1
        bins_poisson_weighted[b] += scale
    
    # Hash: unweighted and weighted
    bins_hash_unweighted = defaultdict(int)
    bins_hash_weighted = defaultdict(float)
    for size, weight in live_hash.values():
        b = (size // size_bin) * size_bin
        bins_hash_unweighted[b] += 1
        scale = weight / size if size > 0 else 1
        bins_hash_weighted[b] += scale
    
    # Get all bin keys
    all_bins = sorted(set(bins_truth.keys()) | set(bins_poisson_unweighted.keys()) | set(bins_hash_unweighted.keys()))
    
    if not all_bins:
        print("No data to plot")
        return
    
    # Convert to lists aligned with bin keys
    truth_counts = [bins_truth.get(b, 0) for b in all_bins]
    pois_counts_unw = [bins_poisson_unweighted.get(b, 0) for b in all_bins]
    hash_counts_unw = [bins_hash_unweighted.get(b, 0) for b in all_bins]
    
    pois_counts_weighted = [bins_poisson_weighted.get(b, 0) for b in all_bins]
    hash_counts_weighted = [bins_hash_weighted.get(b, 0) for b in all_bins]
    
    # ---- PLOT 1: UNWEIGHTED (raw sample counts) ----
    plt.figure(figsize=(14, 7))
    
    # Use line plots for better overlay visibility
    plt.plot(all_bins, truth_counts, 'o-', label='Ground Truth', linewidth=2, markersize=4)
    plt.plot(all_bins, pois_counts_unw, 's--', label='Poisson (samples)', linewidth=2, markersize=4, alpha=0.7)
    plt.plot(all_bins, hash_counts_unw, '^--', label='Stateless Hash (samples)', linewidth=2, markersize=4, alpha=0.7)
    
    plt.xlabel("Allocation Size (bytes)", fontsize=12)
    plt.ylabel("Number of Allocations", fontsize=12)
    plt.title(f"Live Heap at T+{elapsed_time:.3f}s - Raw Samples", fontsize=14)
    plt.legend(fontsize=11)
    plt.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(filename_unweighted, dpi=300, bbox_inches='tight')
    plt.close()
    
    # ---- PLOT 2: WEIGHTED (estimated counts) ----
    plt.figure(figsize=(14, 7))
    
    plt.plot(all_bins, truth_counts, 'o-', label='Ground Truth', linewidth=2, markersize=4)
    plt.plot(all_bins, pois_counts_weighted, 's--', label='Poisson (weighted)', linewidth=2, markersize=4, alpha=0.7)
    plt.plot(all_bins, hash_counts_weighted, '^--', label='Stateless Hash (weighted)', linewidth=2, markersize=4, alpha=0.7)
    
    plt.xlabel("Allocation Size (bytes)", fontsize=12)
    plt.ylabel("Estimated Number of Allocations", fontsize=12)
    plt.title(f"Live Heap at T+{elapsed_time:.3f}s - Weighted Estimates", fontsize=14)
    plt.legend(fontsize=11)
    plt.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(filename_weighted, dpi=300, bbox_inches='tight')
    plt.close()
    
    print(f"Saved: {filename_unweighted}")
    print(f"Saved: {filename_weighted}")

# ---- STATISTICS FUNCTIONS ----

def compute_statistics(log_path):
    """
    Compute statistics to validate sampling rates:
    - Total allocations
    - Poisson: sample count, sampling rate
    - Hash: sample count, sampling rate (should be ~1/256)
    """
    
    total_mallocs = 0
    poisson_sampled = 0
    hash_sampled = 0
    total_bytes = 0
    poisson_bytes = 0
    hash_bytes = 0
    
    with open(log_path) as f:
        for line in f:
            line = line.strip()
            if not line or not line.startswith("MALLOC"):
                continue
            
            parts = [x.strip() for x in line.split(",")]
            if len(parts) != 8:
                continue
            
            try:
                _, _, _, actual_size, pois_tracked, pois_size, hash_tracked, hash_size = parts
                actual_size = int(actual_size)
                pois_tracked = int(pois_tracked)
                hash_tracked = int(hash_tracked)
                
                total_mallocs += 1
                total_bytes += actual_size
                
                if pois_tracked:
                    poisson_sampled += 1
                    poisson_bytes += int(pois_size)
                
                if hash_tracked:
                    hash_sampled += 1
                    hash_bytes += int(hash_size)
            except:
                continue
    
    print("\n" + "="*60)
    print("SAMPLING STATISTICS")
    print("="*60)
    print(f"Total allocations: {total_mallocs:,}")
    print(f"Total bytes: {total_bytes:,}")
    print()
    
    if total_mallocs > 0:
        pois_rate = poisson_sampled / total_mallocs
        print(f"Poisson:")
        print(f"  Sampled: {poisson_sampled:,} allocations ({pois_rate:.4%})")
        print(f"  Tracked bytes: {poisson_bytes:,}")
        print()
        
        hash_rate = hash_sampled / total_mallocs
        expected_rate = 1/256
        print(f"Stateless Hash:")
        print(f"  Sampled: {hash_sampled:,} allocations ({hash_rate:.4%})")
        print(f"  Expected rate: {expected_rate:.4%} (1/256)")
        print(f"  Deviation: {abs(hash_rate - expected_rate)/expected_rate:.2%}")
        print(f"  Tracked bytes: {hash_bytes:,}")
    
    print("="*60)

# ---- MAIN ----
if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 agg_live_heap_combined.py <logfile> <num_bins> [--stats]")
        sys.exit(1)
    
    log_file = sys.argv[1]
    num_bins = int(sys.argv[2])
    show_stats = "--stats" in sys.argv
    
    print(f"Processing: {log_file}")
    print(f"Number of bins: {num_bins}")
    print()
    
    process_combined_file(log_file, num_bins)
    
    if show_stats:
        compute_statistics(log_file)
