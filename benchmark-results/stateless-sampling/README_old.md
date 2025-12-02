# True Stateless Sampling Experiments

This directory will contain experiments with **true stateless sampling** - no headers, just hash functions and external storage.

## Approach

```c
// No headers at all!
void *malloc(size_t size) {
    void *ptr = real_malloc(size);  // Normal allocation
    
    if (should_sample_stateless(ptr)) {
        // Store in external hash table
        hash_table_insert(ptr, {
            .size = size,
            .timestamp = now(),
            .stack_trace = capture_stack()
        });
    }
    
    return ptr;  // Return as-is
}

void free(void *ptr) {
    if (should_sample_stateless(ptr)) {  // Re-hash!
        hash_table_remove(ptr);
    }
    real_free(ptr);
}

bool should_sample_stateless(void *ptr) {
    return (hash(ptr) & 0xFF) == 0;  // Deterministic
}
```

## Key Differences from Current Implementation

| Aspect | Current (all-headers) | True Stateless |
|--------|----------------------|----------------|
| Headers | 16 bytes per alloc | None |
| Decision | Hash + store in header | Hash only |
| On free | Read header | Re-hash |
| External storage | None | Hash table |

## Variants to Test

### 1. Hash Function Comparison
- **XOR-shift** (current)
- **FNV-1a** (fast, good distribution)
- **Murmur3** (slower, excellent distribution)
- **CityHash** (optimized for x86)

### 2. Sampling Rates
- 1/64 (1.56%)
- 1/128 (0.78%)
- 1/256 (0.39%) ← current target
- 1/512 (0.20%)
- 1/1024 (0.10%)

### 3. Stateless Poisson
Instead of thread-local counter, derive counter from address:
```c
bool should_sample_stateless_poisson(void *ptr, size_t size) {
    uint64_t h = hash(ptr);
    uint64_t threshold = (mean_bytes * 0xFFFFFFFF) / size;
    return (h & 0xFFFFFFFF) < threshold;
}
```

### 4. Page-Based Variants
- Hash page number (current PAGE_HASH)
- Hash with page-level caching
- Adaptive: switch to per-allocation if working set is small

## Implementation TODO

- [ ] Create `libsampler_stateless.so`
- [ ] Implement lock-free hash table for tracking
- [ ] Add different hash function variants
- [ ] Measure memory overhead (hash table size)
- [ ] Measure CPU overhead (hash + lookup vs header read)
- [ ] Test on all workloads
- [ ] Compare to header-based approaches

## Expected Results

**Hypothesis:**
- ✅ Lower memory overhead (no headers)
- ❌ Higher CPU overhead (hash table operations)
- ❌ Address reuse bias (same as current STATELESS_HASH)
- ⚠️ Scalability concerns (hash table contention)

**Key question:** Is the memory savings worth the complexity?

## Directory Structure (Planned)

```
stateless-sampling/
├── README.md (this file)
├── Makefile
├── src/
│   ├── sampler_stateless.c
│   ├── hash_functions.c (FNV, murmur, city)
│   └── hash_table.c (lock-free tracking)
├── experiments/
│   ├── hash_comparison.sh
│   ├── rate_comparison.sh
│   └── overhead_measurement.sh
└── results/
    └── (experiment outputs)
```

## Running Experiments (Future)

Once implemented:

```bash
# Build stateless sampler
make

# Run with different hash functions
cd ../workloads
SAMPLER_LIB=../stateless-sampling/libsampler_stateless.so \
HASH_FUNCTION=fnv1a \
./run_workload.sh monotonic STATELESS_HASH /tmp/fnv.json

# Compare to header-based
SAMPLER_LIB=../../stateless-sampling/sampler/libsampler.so \
./run_workload.sh monotonic STATELESS_HASH /tmp/header.json
```

## References

- ddprof approach: Stateless decision, external storage
- Current implementation: `../../stateless-sampling/sampler/sampler.c`
