import sys

def process_file(path, num_bins):
    # ---- 1. READ AND SORT BY SECOND COLUMN ----
    records = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            parts = [x.strip() for x in line.split(",")]
            try:
                op, ts, addr, size = parts
            except ValueError:
                print(line, file=sys.stderr, flush=True)
                raise  # re-raise so you still get the traceback
            ts = float(ts)
            size = int(size) 

            records.append((op, ts, addr, size))

    # sort by timestamp (column 2)
    records.sort(key=lambda x: x[1])

    total_rows = len(records)

    # ---- 2. DETERMINE BIN BOUNDARIES BASED ON ROW COUNT ----
    # bin_size means number of rows per bin
    # Example: 1000 rows, bin_size=10 => boundaries at 10, 20, 30, …
    bin_size = (total_rows + num_bins - 1) // num_bins  # ceiling division
    # Bin boundaries are the row indices where we want to output
    bin_boundaries = set(range(bin_size, total_rows + 1, bin_size))

    # ---- 3. SIMULATE MALLOC/FREE AND TRACK LIVE ALLOCATIONS ----
    live = {}     # addr -> size
    next_boundary = bin_size
    started = False
    # ---- 4. WHEN ROW INDEX HITS BOUNDARY, PRINT HISTOGRAM ----
    for idx, (op, ts, addr, size) in enumerate(records, start=1):
        if op == "START":
            started = True
            continue
        if (not started):
            continue

        if op == "END":
            break

        if op == "MALLOC":
            live[addr] = size
        elif op == "FREE":
            live.pop(addr, None)

        # If we've reached a bin boundary, output histogram
        if idx in bin_boundaries:
            print(f"\n=== BIN END @ ROW {idx} ===")
            print_histogram(live, sys.argv[1][:6], idx)

def print_histogram(live_dict, path, i):
    print(live_dict)
    import matplotlib.pyplot as plt
    from collections import Counter
    filename = f"{path}_{i}.png"
    size_bin = 256

    sizes = [int(size) for size in live_dict.values()]

    # Bin allocation sizes
    max_size = max(sizes)
    bins = list(range(0, max_size + size_bin, size_bin))

    # Count allocations in each size bin
    bin_counts = Counter()
    for s in sizes:
        b = (s // size_bin) * size_bin
        bin_counts[b] += 1

    # Prepare data
    x_bins = sorted(bin_counts.keys())  # allocation size bins
    counts = [bin_counts[b] for b in x_bins]

    # Plot vertical bars
    plt.figure(figsize=(12, 6))
    plt.bar(x_bins, counts, width=size_bin, align='edge', color='skyblue', alpha=0.7)

    # Axes labels
    plt.xlabel("Allocation Size (bytes)")
    plt.ylabel("Number of Allocations")
    plt.title("Live Heap Area Visualization (bars grow from x-axis)")

    # Force axes to start at zero
    plt.xlim(0, max(x_bins) + size_bin)
    plt.ylim(0, max(counts) * 1.1)

    plt.grid(True, axis='y', alpha=0.5)

    # Save the plot
    plt.savefig(filename, dpi=300, bbox_inches='tight')
    plt.close()


# ---- main entry point ----
if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 agg_live_heap.py <inputfile> <bin_size>")
        sys.exit(1)

    process_file(sys.argv[1], int(sys.argv[2]))
