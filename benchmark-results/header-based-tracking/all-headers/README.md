# All-Headers Approach

This directory represents experiments with the **current implementation** where every allocation gets a header.

## Approach

The existing `stateless-sampling/sampler/` implementation uses this approach:

```c
void *malloc(size_t size) {
    // Every allocation gets 16-byte header
    size_t total_size = size + HEADER_SIZE;
    void *ptr = real_malloc(total_size);
    
    SampleHeader *header = (SampleHeader *)ptr;
    void *user_ptr = (char *)ptr + HEADER_SIZE;
    
    header->magic = SAMPLE_MAGIC;
    header->flags = should_sample(ptr, size) ? FLAG_SAMPLED : 0;
    header->reserved = (uint32_t)size;
    
    return user_ptr;
}
```

## Characteristics

| Property | Value |
|----------|-------|
| **Header size** | 16 bytes |
| **Headers on** | 100% of allocations |
| **Memory overhead** | 16 × total_allocs |
| **External state** | None (all in headers) |
| **Decision complexity** | O(1) (hash or counter) |
| **Free complexity** | O(1) (read header) |

## Trade-offs

✅ **Advantages:**
- Simple to implement
- No external data structures needed
- Can always read header on free
- Consistent memory layout

❌ **Disadvantages:**
- High memory overhead (16 bytes × ALL allocations)
- Cache pollution (extra cache line per allocation)
- Wasted space on non-sampled allocations

## Experiments

Since this is the **current implementation**, we use it as the baseline for comparison.

### Running Experiments

The existing sampler library IS this approach:

```bash
cd ../../workloads

# Run any workload with any scheme
SAMPLER_LIB=../../stateless-sampling/sampler/libsampler.so \
./run_workload.sh monotonic STATELESS_HASH /tmp/all_headers.json
```

### Results Location

All results from the original `stateless-sampling/` experiments use this approach:
- `../../stateless-sampling/results/`
- `../../stateless-sampling/results_package.txt`

## Comparison to Other Approaches

| Approach | Memory Overhead | CPU Overhead | Implementation |
|----------|----------------|--------------|----------------|
| **All-headers (this)** | 16 × N allocs | Low (header read) | Simple |
| Sample-headers | 16 × N/256 allocs | Medium (hash lookup) | Complex |
| True stateless | ~0.5 × N/256 allocs | Medium-High (hash table) | Complex |

Where N = total allocations.

### Example Calculation

For 1 million allocations:

| Approach | Memory Overhead |
|----------|----------------|
| **All-headers** | 16 MB |
| Sample-headers (1/256) | 62.5 KB |
| True stateless (1/256) | ~30 KB (hash table entries) |

**256× difference** between all-headers and selective approaches!

## Why This Exists

This approach was chosen for the original `stateless-sampling` research because:

1. **Simplicity** - Easy to implement correctly
2. **Focus** - Research goal was comparing *decision algorithms*, not storage mechanisms
3. **Consistency** - Same overhead for all schemes (fair comparison)

For production, we'd want to test more efficient storage approaches.

## Future Work

- [ ] Measure actual memory consumption (RSS, heap size)
- [ ] Profile cache behavior (L1/L2/L3 misses)
- [ ] Test fragmentation impact
- [ ] Compare to sample-headers and true stateless

## References

- Implementation: `../../stateless-sampling/sampler/sampler.c`
- Documentation: `../../stateless-sampling/VISUAL_EXPLANATION.md`
- Results: `../../stateless-sampling/FOR_DANIELLE_START_HERE.md`
