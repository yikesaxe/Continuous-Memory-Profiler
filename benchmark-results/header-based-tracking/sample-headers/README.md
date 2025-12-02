# Sample-Headers Only Approach

This directory will contain experiments where **only sampled allocations get headers**.

## Approach

```c
void *malloc(size_t size) {
    bool sampled = should_sample_before_alloc(size);
    
    if (sampled) {
        // Add header for sampled allocation
        size_t total_size = size + HEADER_SIZE;
        void *ptr = real_malloc(total_size);
        
        SampleHeader *header = (SampleHeader *)ptr;
        void *user_ptr = (char *)ptr + HEADER_SIZE;
        
        header->magic = SAMPLE_MAGIC;
        header->size = size;
        
        // Track that this pointer has a header
        hash_table_insert(user_ptr, HAS_HEADER_FLAG);
        
        return user_ptr;
    } else {
        // No header! Just allocate normally
        return real_malloc(size);
    }
}

void free(void *ptr) {
    if (hash_table_lookup(ptr) == HAS_HEADER_FLAG) {
        // It has a header
        SampleHeader *header = (SampleHeader *)((char *)ptr - HEADER_SIZE);
        update_stats(header->size, true);
        real_free(header);
        hash_table_remove(ptr);
    } else {
        // No header
        real_free(ptr);
    }
}
```

## Characteristics

| Property | Value |
|----------|-------|
| **Header size** | 16 bytes |
| **Headers on** | ~0.39% of allocations (1/256) |
| **Memory overhead** | 16 × (N/256) + hash_table |
| **External state** | Hash table ("has header" tracking) |
| **Decision complexity** | O(1) (hash) |
| **Free complexity** | O(1) avg (hash lookup) |

## Key Challenges

### 1. realloc() Complexity

```c
void *realloc(void *ptr, size_t new_size) {
    bool old_had_header = hash_table_lookup(ptr);
    bool new_should_sample = should_sample_before_alloc(new_size);
    
    if (old_had_header && new_should_sample) {
        // Easy: both have headers, use real_realloc
        Header *h = (Header *)((char *)ptr - HEADER_SIZE);
        void *new_base = real_realloc(h, new_size + HEADER_SIZE);
        // ... update header ...
        return (char *)new_base + HEADER_SIZE;
        
    } else if (old_had_header && !new_should_sample) {
        // Remove header: copy data, free old
        Header *h = (Header *)((char *)ptr - HEADER_SIZE);
        void *new_ptr = real_malloc(new_size);
        memcpy(new_ptr, ptr, min(h->size, new_size));
        real_free(h);
        hash_table_remove(ptr);
        return new_ptr;
        
    } else if (!old_had_header && new_should_sample) {
        // Add header: copy data, add header
        void *new_base = real_malloc(new_size + HEADER_SIZE);
        Header *h = (Header *)new_base;
        void *new_user = (char *)new_base + HEADER_SIZE;
        
        size_t old_size = malloc_usable_size(ptr);
        memcpy(new_user, ptr, min(old_size, new_size));
        real_free(ptr);
        
        h->magic = SAMPLE_MAGIC;
        hash_table_insert(new_user, HAS_HEADER_FLAG);
        return new_user;
        
    } else {
        // Neither has header: normal realloc
        return real_realloc(ptr, new_size);
    }
}
```

This is **much more complex** than all-headers approach!

### 2. Hash Table Overhead

Need to track ~N/256 entries. For 1M allocations:
- Entries: ~3,906
- Memory: ~3,906 × (8 bytes ptr + 8 bytes metadata) = ~62.5 KB
- Plus hash table structure overhead

### 3. Sampling Decision Timing

Must decide **before allocation** to know whether to add header:

```c
// Problem: hash-based sampling
bool should_sample_before_alloc(size_t size) {
    // We don't know the address yet!
    // Can't hash the pointer like STATELESS_HASH does
    
    // Solution 1: Use Poisson only
    return should_sample_poisson(size);
    
    // Solution 2: Pre-allocate, hash, then conditionally add header (wasteful)
    void *temp = real_malloc(size);
    bool sample = (hash(temp) & 0xFF) == 0;
    real_free(temp);
    // ... now allocate with or without header ...
}
```

**This breaks stateless hash!** We'd be forced to use Poisson or stateful sampling.

## Trade-offs

✅ **Advantages:**
- Low memory overhead (headers only on 0.39% of allocs)
- Similar to "true stateless" but with inline metadata

❌ **Disadvantages:**
- Requires hash table (external state)
- Can't use pure address-based sampling (need to decide before allocation)
- Complex realloc() handling
- Hash table lookup overhead on every free

## Variants to Test

### 1. Poisson-Only
Force Poisson sampling (can decide before allocation):
```c
bool should_sample_before_alloc(size_t size) {
    return should_sample_poisson(size);
}
```

### 2. Pre-Allocation Hash
Allocate, check hash, potentially add header:
```c
void *malloc(size_t size) {
    void *ptr = real_malloc(size);
    if (hash(ptr) & 0xFF == 0) {
        // Resample! Need to add header
        void *new_ptr = real_malloc(size + HEADER_SIZE);
        memcpy((char *)new_ptr + HEADER_SIZE, ptr, size);
        real_free(ptr);
        // ... set up header ...
        return (char *)new_ptr + HEADER_SIZE;
    }
    return ptr;
}
```
This is **very wasteful** (2 allocations per sampled object).

### 3. Hybrid: Small Gets Headers, Large Doesn't
```c
// Always add headers to small allocations (< 256 bytes)
// Use stateless hash for large allocations (store in hash table)
```

## Expected Results

**Hypothesis:**
- ✅ Memory overhead ~256× lower than all-headers
- ❌ CPU overhead higher (hash table operations)
- ⚠️ Can't use pure STATELESS_HASH (need Poisson or pre-alloc)
- ⚠️ Implementation complexity much higher

**Key question:** Is the memory savings worth losing address-based sampling?

## Implementation TODO

- [ ] Create `libsampler_selective.so`
- [ ] Implement lock-free hash table for "has header" tracking
- [ ] Handle realloc edge cases
- [ ] Test with Poisson-only sampling
- [ ] Measure memory overhead (headers + hash table)
- [ ] Measure CPU overhead vs all-headers
- [ ] Test on all workloads

## Directory Structure (Planned)

```
sample-headers/
├── README.md (this file)
├── Makefile
├── src/
│   ├── sampler_selective.c
│   ├── has_header_tracking.c
│   └── realloc_handling.c
├── experiments/
│   ├── overhead_vs_all_headers.sh
│   └── poisson_only_test.sh
└── results/
    └── (experiment outputs)
```

## Running Experiments (Future)

Once implemented:

```bash
cd ../../workloads

# Must use Poisson (can't use STATELESS_HASH with this approach)
SAMPLER_LIB=../header-based-tracking/sample-headers/libsampler_selective.so \
./run_workload.sh monotonic POISSON_HEADER /tmp/selective.json

# Compare to all-headers
SAMPLER_LIB=../../stateless-sampling/sampler/libsampler.so \
./run_workload.sh monotonic POISSON_HEADER /tmp/all_headers.json
```

## References

- All-headers implementation: `../../stateless-sampling/sampler/sampler.c`
- ddprof approach: Similar to this, but with true stateless (no headers at all)
