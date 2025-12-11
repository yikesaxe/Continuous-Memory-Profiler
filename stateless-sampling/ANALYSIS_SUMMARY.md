# Stateless Sampling Analysis - Current Status & Understanding

## What You Have Now

### 1. Modified sampler.c
Your changes implement the core weighting system:

**Key Changes:**
- Removed old JSON stats and event logging
- Simplified to CSV output via `printf()`
- Implemented dual accumulation: `running_bytes` (hash) and `bytes_until_next` (poisson)
- **Current output**: Only logs when `reported_size > 0` (sampled allocations)

**What Works:**
- ✅ Accumulates bytes in thread-local state
- ✅ Hash-based sampling with running total
- ✅ Poisson sampling with proper weighting (`nsamples * mean`)
- ✅ CSV format output

**What's Missing:**
- ❌ Ground truth logging (actual size of EVERY allocation)
- ❌ Dual-scheme logging (both hash and poisson results simultaneously)

### 2. Analysis Scripts

**`agg_live_heap.py`** (original):
- Reads simple CSV: `MALLOC/FREE, timestamp, address, size`
- Builds live heap simulation
- Creates histograms at intervals
- **Limitation**: Only handles one data stream, no ground truth comparison

**`analyze_fidelity.py`** (new, just created):
- Compares ground truth vs sampled live heaps
- Generates comparison plots:
  - Live bytes over time
  - Allocation counts over time
  - Relative error
  - Size distribution histograms
- Computes fidelity statistics
- **Current limitation**: Expects ground truth data which your sampler doesn't log yet

## What Your Notes Want

From the meeting notes, the goal is clear:

### Required Logging
```
For each allocation:
1. Ground truth: address + actual_size (always)
2. Poisson: IF sampled, address + weighted_size
3. Hash: IF sampled, address + weighted_size
4. For each free: address (always)
```

### Analysis Goals
1. **Validate sampling rate**: Is hash really achieving 1/256?
2. **Measure fidelity**: How close are estimates to ground truth?
3. **Compare schemes**: Which scheme (poisson vs hash) is more accurate?
4. **Understand bias**: Are certain allocation sizes systematically missed?

## Recommended Next Steps

### Step 1: Enhanced Logging Format

Modify your `sampler.c` to log ALL allocations with multi-scheme tracking:

```c
// In malloc():
void *malloc(size_t size) {
    void *ptr = real_malloc(size);
    clock_gettime(CLOCK_REALTIME, &ts);
    
    // Evaluate BOTH schemes
    size_t poisson_weight = 0, hash_weight = 0;
    
    // Poisson
    tstate.bytes_until_next += size;
    if (should_sample_poisson()) {
        poisson_weight = compute_poisson_weight();
    }
    
    // Hash
    tstate.running_bytes += size;
    if (should_sample_hash(ptr)) {
        hash_weight = tstate.running_bytes;
        tstate.running_bytes = 0;
    }
    
    // Log: timestamp, address, actual_size, poisson_weight, hash_weight
    printf("ALLOC,%ld.%09ld,%p,%zu,%zu,%zu\n",
           ts.tv_sec, ts.tv_nsec, ptr, size, poisson_weight, hash_weight);
    
    return ptr;
}

void free(void *ptr) {
    clock_gettime(CLOCK_REALTIME, &ts);
    printf("FREE,%ld.%09ld,%p\n", ts.tv_sec, ts.tv_nsec, ptr);
    real_free(ptr);
}
```

**Output format:**
```
ALLOC,1702334567.123456789,0x7fff00000000,128,0,0       # Not sampled by either
ALLOC,1702334567.123456790,0x7fff00000100,256,4096,0    # Poisson sampled (weight=4096)
ALLOC,1702334567.123456791,0x7fff00000200,64,0,8192     # Hash sampled (weight=8192)
FREE,1702334567.123456792,0x7fff00000000                # Free first allocation
```

### Step 2: Enhanced Analysis Script

Create `analyze_multitrack.py`:

```python
# Parse enhanced logs
for line in log:
    if line.startswith("ALLOC"):
        _, ts, addr, actual_size, pois_weight, hash_weight = parse(line)
        
        # Ground truth heap
        gt_heap[addr] = actual_size
        
        # Poisson heap
        if pois_weight > 0:
            poisson_heap[addr] = pois_weight
            poisson_sample_count += 1
        
        # Hash heap
        if hash_weight > 0:
            hash_heap[addr] = hash_weight
            hash_sample_count += 1
            
        total_alloc_count += 1
    
    elif line.startswith("FREE"):
        _, ts, addr = parse(line)
        gt_heap.pop(addr, None)
        poisson_heap.pop(addr, None)
        hash_heap.pop(addr, None)

# Compute metrics
print(f"Hash sample rate: {hash_sample_count / total_alloc_count * 100:.4f}%")
print(f"Expected: {1/256 * 100:.4f}%")

# Compare live heaps
gt_bytes = sum(gt_heap.values())
poisson_bytes = sum(poisson_heap.values())
hash_bytes = sum(hash_heap.values())

print(f"Ground truth: {gt_bytes:,} bytes")
print(f"Poisson est:  {poisson_bytes:,} bytes ({relative_error}% error)")
print(f"Hash est:     {hash_bytes:,} bytes ({relative_error}% error)")
```

### Step 3: Run Benchmarks

```bash
# Compile
cd stateless-sampling/sampler && make

# Run synthetic workloads
LD_PRELOAD=./sampler/libsampler.so \
SAMPLER_SCHEME=STATELESS_HASH \
SAMPLER_POISSON_MEAN_BYTES=4096 \
./bench/bench_alloc_patterns > logs/synthetic.csv 2>&1

# Run real-world (e.g., curl build)
LD_PRELOAD=./sampler/libsampler.so \
SAMPLER_SCHEME=STATELESS_HASH \
SAMPLER_POISSON_MEAN_BYTES=4096 \
make -C curl clean all > logs/curl_build.csv 2>&1

# Analyze
python3 analyze_multitrack.py logs/synthetic.csv --output results/synthetic/
python3 analyze_multitrack.py logs/curl_build.csv --output results/curl/
```

## Understanding the Weighting System

### Why Weight Samples?

**Problem**: If you only track 1 out of 256 allocations, your live heap size will appear 256× smaller than reality.

**Solution**: Weight each tracked allocation by the expected number of untracked allocations it represents.

### Hash-Based Weighting

```
running_bytes = 0

malloc(128):  running_bytes = 128,  hash=0x1234 → NO SAMPLE
malloc(256):  running_bytes = 384,  hash=0x0000 → SAMPLE! Report 384 bytes
malloc(64):   running_bytes = 64,   hash=0x5678 → NO SAMPLE
malloc(512):  running_bytes = 576,  hash=0x0100 → SAMPLE! Report 576 bytes
```

**Key insight**: The `running_bytes` accumulates ALL bytes (sampled and unsampled) since the last sample. When we hit a sample, we report the accumulated total.

### Poisson Weighting

```
mean_interval = 4096 bytes
bytes_until_next = -2048 (starts negative, draw first interval)

malloc(1024):  bytes_until_next = -2048 + 1024 = -1024 → NO SAMPLE
malloc(2048):  bytes_until_next = -1024 + 2048 = 1024  → CROSSED!
               # We crossed from negative to positive
               # This allocation "triggered" 1 sample
               # Report: 1 * 4096 = 4096 bytes
               # Draw new interval: -3456
               bytes_until_next = -3456
```

**Key insight**: The counter tracks when we cross a sampling boundary. When we do, we report `mean_interval * num_crossings`.

## Current Analysis Understanding

### agg_live_heap.py - How It Works

**Input**: CSV with `MALLOC/FREE, timestamp, address, size`

**Algorithm**:
1. Sort events by timestamp
2. Divide events into N bins (e.g., 20)
3. For each bin:
   - Process malloc/free events
   - Track live allocations in dict: `{address: size}`
   - At bin boundary, create histogram of sizes
4. Output: PNG histograms showing size distribution at different time points

**Use case**: Visualize how heap shape changes over time

**Limitations**:
- No ground truth comparison
- Only one tracking method
- Doesn't compute error metrics

### analyze_fidelity.py - How It Should Work

**Input**: Enhanced CSV with ground truth + sampled data

**Algorithm**:
1. Parse events, tracking three heaps simultaneously:
   - `gt_heap`: Ground truth (all allocations)
   - `sampled_heap`: Weighted samples
2. At intervals, take snapshots of both heaps
3. Compute relative error: `|sampled - gt| / gt * 100%`
4. Generate comparison plots
5. Compute statistics (mean/median error, etc.)

**Output**:
- Line plots showing heap size over time (both heaps)
- Error plot showing accuracy
- Histograms comparing size distributions
- Statistical summary

## Validation Questions (From Your Notes)

### 1. "Validate whether 1/256 is actually happening (stateless)"

**How to check:**
```python
sample_rate = sampled_count / total_count
expected_rate = 1 / 256  # 0.00390625

print(f"Actual:   {sample_rate:.6f}")
print(f"Expected: {expected_rate:.6f}")
print(f"Ratio:    {sample_rate / expected_rate:.2f}x")
```

**What you're looking for:**
- Ratio near 1.0 = hash is working correctly
- Ratio > 1.5 = sampling too much (hash collision?)
- Ratio < 0.5 = sampling too little (bias toward unsampled addresses)

### 2. "How close is the profile to the ground truth?"

**Metrics:**
- **Mean relative error**: Average of `|sampled - gt| / gt` across time
- **Max relative error**: Worst-case snapshot
- **Distribution comparison**: Do histograms have similar shape?

**Good profile**: Mean error < 10%, max error < 25%
**Acceptable profile**: Mean error < 25%, max error < 50%
**Bad profile**: Mean error > 50% or highly variable

### 3. "Histogram of sampling partners (size of allocation)"

This means: **For sampled allocations, what sizes are being tracked?**

```python
sampled_sizes = []
for alloc in allocations:
    if alloc.was_sampled:
        sampled_sizes.append(alloc.actual_size)

# Plot histogram
plt.hist(sampled_sizes, bins=50)
plt.xlabel("Allocation Size (bytes)")
plt.ylabel("Number of Sampled Allocations")
plt.title("Size Distribution of Sampled Allocations")
```

**What to look for:**
- Uniform distribution across sizes = good (unbiased)
- Missing size ranges = bad (systematic bias)
- Over-representation of large allocations = expected for byte-based sampling

## File Structure Summary

```
stateless-sampling/
├── sampler/
│   ├── sampler.c              # Modified: logs CSV events
│   ├── sampler.h              # Header definitions
│   └── libsampler.so          # Compiled library
├── bench/
│   └── bench_alloc_patterns   # Synthetic benchmark
├── agg_live_heap.py           # Original: basic histogram tool
├── analyze_fidelity.py        # New: ground truth comparison
├── FIDELITY_ANALYSIS_GUIDE.md # Comprehensive guide
└── ANALYSIS_SUMMARY.md        # This file
```

## Quick Reference: Common Tasks

### Compile sampler
```bash
cd stateless-sampling/sampler && make
```

### Run with logging
```bash
LD_PRELOAD=./sampler/libsampler.so \
SAMPLER_SCHEME=STATELESS_HASH \
./bench/bench_alloc_patterns > output.csv 2>&1
```

### Analyze logs
```bash
python3 analyze_fidelity.py output.csv --bins 20 --output-dir results/
```

### Check sample rate
```bash
grep "^MALLOC" output.csv | wc -l  # Total allocations
grep "^MALLOC.*,[1-9]" output.csv | wc -l  # Sampled (non-zero weight)
```

## Next Immediate Actions

1. ✅ Understanding of current system (this document)
2. ⏳ Modify `sampler.c` to log ground truth + dual schemes
3. ⏳ Create `analyze_multitrack.py` for dual-scheme comparison
4. ⏳ Run benchmarks with new logging
5. ⏳ Generate fidelity reports
6. ⏳ Answer validation questions with data

