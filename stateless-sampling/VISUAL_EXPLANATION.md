# Visual Explanation: Stateless Sampling Implementation

This document explains how the stateless sampling library works, from LD_PRELOAD interception to each sampling scheme's algorithm.

---

## 1. LD_PRELOAD: How We Intercept malloc/free

### 1.1 What is LD_PRELOAD?

`LD_PRELOAD` is a Linux mechanism that allows you to load a shared library **before** any other libraries. This lets us intercept function calls.

```
┌─────────────────────────────────────────────────────────┐
│  Application calls malloc(100)                          │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│  Dynamic Linker (ld.so)                                 │
│  ┌───────────────────────────────────────────────────┐  │
│  │ 1. Check LD_PRELOAD=libsampler.so                 │  │
│  │ 2. Load libsampler.so FIRST                       │  │
│  │ 3. Our malloc() overrides glibc's malloc()       │  │
│  └───────────────────────────────────────────────────┘  │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│  Our malloc() wrapper (libsampler.so)                  │
│  ┌───────────────────────────────────────────────────┐  │
│  │ • Add header metadata                             │  │
│  │ • Decide: sample or not?                          │  │
│  │ • Call real malloc() via dlsym(RTLD_NEXT)        │  │
│  │ • Update statistics                               │  │
│  └───────────────────────────────────────────────────┘  │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│  Real malloc() (glibc)                                  │
│  ┌───────────────────────────────────────────────────┐  │
│  │ • Actual memory allocation                        │  │
│  │ • Returns pointer to memory                       │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### 1.2 Code: Getting the Real Functions

```c
// We use dlsym(RTLD_NEXT, "malloc") to get the REAL malloc
// RTLD_NEXT means "find the NEXT symbol in the search order"
// Since we're loaded first, "next" is glibc's malloc

static void *(*real_malloc)(size_t) = NULL;
static void (*real_free)(void *) = NULL;

static void init_sampler() {
    // Get pointers to the REAL functions
    real_malloc = dlsym(RTLD_NEXT, "malloc");
    real_free = dlsym(RTLD_NEXT, "free");
    // ... parse environment variables ...
}
```

---

## 2. Memory Layout: Header Wrapping

Every allocation is wrapped with a 16-byte header containing metadata.

### 2.1 Memory Structure

```
┌─────────────────────────────────────────────────────────────┐
│  What the user requests: malloc(100)                         │
└─────────────────────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│  What we actually allocate: malloc(100 + 16)                 │
│                                                              │
│  ┌──────────────────┬──────────────────────────────────┐   │
│  │  SampleHeader    │  User's Data (100 bytes)         │   │
│  │  (16 bytes)      │                                   │   │
│  ├──────────────────┼──────────────────────────────────┤   │
│  │ magic: 0x...     │  [User's 100 bytes here]        │   │
│  │ flags: 0x0/0x1   │                                   │   │
│  │ reserved: 100     │                                   │   │
│  └──────────────────┴──────────────────────────────────┘   │
│  ▲                                                          │
│  │                                                          │
│  real_ptr (returned by glibc malloc)                       │
│                                                              │
│  ┌──────────────────────────────────────────────────┐      │
│  │ user_ptr = real_ptr + 16                         │      │
│  │ (returned to application)                        │      │
│  └──────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Code: Wrapping Allocations

```c
void *malloc(size_t size) {
    // Allocate extra space for header
    size_t total_size = size + HEADER_SIZE;  // size + 16
    
    // Call REAL malloc
    void *ptr = real_malloc(total_size);
    
    // Header is at the beginning
    SampleHeader *header = (SampleHeader *)ptr;
    
    // User pointer is offset by 16 bytes
    void *user_ptr = (char *)ptr + HEADER_SIZE;
    
    // Initialize header
    header->magic = SAMPLE_MAGIC;  // 0xDDBEEFCAFEBABE01
    header->flags = is_sampled ? FLAG_SAMPLED : 0;
    header->reserved = (uint32_t)size;  // Store original size
    
    return user_ptr;  // Return pointer to user's data
}
```

### 2.3 Code: Unwrapping on free()

```c
void free(void *ptr) {
    if (!ptr) return;
    
    // User gave us user_ptr, we need to get back to header
    void *real_ptr = (char *)ptr - HEADER_SIZE;
    
    SampleHeader *header = (SampleHeader *)real_ptr;
    
    // Verify it's ours (safety check)
    if (header->magic != SAMPLE_MAGIC) {
        // Foreign pointer! Handle specially (see realloc section)
        real_free(ptr);
        return;
    }
    
    // Get original size and sampling flag
    size_t size = header->reserved;
    bool is_sampled = (header->flags & FLAG_SAMPLED) != 0;
    
    // Update stats
    update_stats_free(size, is_sampled);
    
    // Free the real pointer (includes header)
    real_free(real_ptr);
}
```

---

## 3. Sampling Schemes: How Each Works

### 3.1 STATELESS_HASH: Address-Based Hash

**Principle**: Hash the pointer address, sample if hash matches pattern.

```
┌─────────────────────────────────────────────────────────────┐
│  Allocation: malloc(100) at address 0x7f8a3c001000          │
└─────────────────────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│  Step 1: Hash the address                                   │
│                                                              │
│  address = 0x7f8a3c001000                                    │
│  hash = XOR_shift(address)                                  │
│  hash = 0x...a3f2c1d4...                                     │
└────────────────────┬───────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│  Step 2: Check if we should sample                          │
│                                                              │
│  if (hash & 0xFF == 0) {  // Last 8 bits are zero?         │
│      SAMPLE = YES                                            │
│  } else {                                                    │
│      SAMPLE = NO                                             │
│  }                                                           │
│                                                              │
│  Example:                                                   │
│  hash = 0x...a3f2c100  →  Last byte = 0x00  →  SAMPLE ✓    │
│  hash = 0x...a3f2c1d4  →  Last byte = 0xd4  →  SKIP ✗      │
└─────────────────────────────────────────────────────────────┘
```

**Visual Example**:

```
Memory Addresses:
┌─────────────┬─────────────┬─────────────┬─────────────┐
│ 0x1000      │ 0x2000      │ 0x3000      │ 0x4000      │
│ hash: 0x... │ hash: 0x... │ hash: 0x... │ hash: 0x... │
│ ...00       │ ...d4       │ ...00       │ ...a1       │
│ ✓ SAMPLE    │ ✗ SKIP      │ ✓ SAMPLE    │ ✗ SKIP      │
└─────────────┴─────────────┴─────────────┴─────────────┘

Problem: If address 0x2000 is reused 1000 times,
         it will NEVER be sampled (always hashes to 0xd4)
```

**Code**:
```c
static bool should_sample(void *ptr, size_t size) {
    uintptr_t h = (uintptr_t)ptr;
    // XOR-shift hash
    h ^= h >> 12;
    h ^= h << 25;
    h ^= h >> 27;
    // Check if last 8 bits are zero (1 in 256 chance)
    return (h & 0xFF) == 0;
}
```

---

### 3.2 POISSON_HEADER: Byte-Based Poisson Process

**Principle**: Sample based on bytes allocated, not addresses. Use a counter that decrements with each allocation.

```
┌─────────────────────────────────────────────────────────────┐
│  Thread-Local State (per thread)                            │
│                                                              │
│  bytes_until_next = 2500  (randomly initialized)          │
│  └─> "Sample after 2500 more bytes are allocated"         │
└─────────────────────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│  Allocation 1: malloc(1000)                                │
│                                                              │
│  bytes_until_next -= 1000                                  │
│  bytes_until_next = 2500 - 1000 = 1500                     │
│                                                              │
│  1500 > 0  →  SKIP ✗                                        │
└────────────────────┬───────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│  Allocation 2: malloc(2000)                                │
│                                                              │
│  bytes_until_next -= 2000                                  │
│  bytes_until_next = 1500 - 2000 = -500                      │
│                                                              │
│  -500 <= 0  →  SAMPLE ✓                                     │
│                                                              │
│  Reset: bytes_until_next = random_geometric(mean=4096)    │
│         bytes_until_next = 3200  (new random value)        │
└─────────────────────────────────────────────────────────────┘
```

**Visual Timeline**:

```
Bytes Allocated:  0    1000   3000   5000   7000   9000
                  │     │      │      │      │      │
Allocations:      └─1000┘      └─2000┘      └─2000┘
                  (skip)        (SAMPLE!)   (skip)
                  
Counter:         2500 → 1500 → -500 → 3200 → 1200 → -800
                 (init)        (reset)              (reset)
                 
Result:          ✗      ✗      ✓      ✗      ✗      ✓
```

**Code**:
```c
// Thread-local state (no synchronization needed)
static __thread ThreadSamplerState tstate = {
    .bytes_until_next = -1,  // -1 means "not initialized"
    .rng_state = 0xDEADBEEFCAFEBABE
};

static bool should_sample_alloc_poisson(size_t size) {
    // Initialize if needed
    if (tstate.bytes_until_next < 0) {
        tstate.bytes_until_next = draw_geometric_bytes(4096);
    }
    
    // Decrement counter
    tstate.bytes_until_next -= (long)size;
    
    // Check if we should sample
    if (tstate.bytes_until_next <= 0) {
        // Reset counter for next sample
        tstate.bytes_until_next = draw_geometric_bytes(4096);
        return true;  // SAMPLE!
    }
    return false;  // SKIP
}
```

**Why it's immune to address reuse**:
- Even if the same address is reused 1000 times, we still decrement the counter
- When counter hits 0, we sample regardless of address
- Address doesn't matter, only bytes allocated

---

### 3.3 PAGE_HASH: Page-Based Hash

**Principle**: Hash the **page number** instead of the full address. Sample ALL allocations on "sampled pages".

```
┌─────────────────────────────────────────────────────────────┐
│  Memory Layout (4KB pages)                                   │
│                                                              │
│  Page 0x1000:  [alloc1] [alloc2] [alloc3]                 │
│  Page 0x2000:  [alloc4] [alloc5]                            │
│  Page 0x3000:  [alloc6] [alloc7] [alloc8] [alloc9]         │
│  Page 0x4000:  [alloc10]                                    │
└─────────────────────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│  Step 1: Extract page number                               │
│                                                              │
│  address = 0x7f8a3c001234                                   │
│  page = address >> 12  // Divide by 4096                    │
│  page = 0x7f8a3c001                                         │
└────────────────────┬───────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│  Step 2: Hash the page number                               │
│                                                              │
│  hash = XOR_shift(page)                                     │
│  hash = 0x...a3f2c100                                       │
└────────────────────┬───────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│  Step 3: Check if page is sampled                           │
│                                                              │
│  if (hash & 0xFF == 0) {                                    │
│      SAMPLE ALL allocations on this page                    │
│  }                                                           │
└─────────────────────────────────────────────────────────────┘
```

**Visual Example**:

```
Pages in Memory:
┌─────────────┬─────────────┬─────────────┬─────────────┐
│ Page 0x1000 │ Page 0x2000 │ Page 0x3000 │ Page 0x4000 │
│ hash: ...00 │ hash: ...d4  │ hash: ...00 │ hash: ...a1 │
│ ✓ SAMPLED   │ ✗ NOT        │ ✓ SAMPLED   │ ✗ NOT       │
│             │              │             │             │
│ [alloc1] ✓ │ [alloc4] ✗   │ [alloc6] ✓ │ [alloc10] ✗ │
│ [alloc2] ✓ │ [alloc5] ✗   │ [alloc7] ✓ │             │
│ [alloc3] ✓ │              │ [alloc8] ✓ │             │
│             │              │ [alloc9] ✓ │             │
└─────────────┴─────────────┴─────────────┴─────────────┘

Problem: If application only uses pages 0x2000 and 0x4000,
         and neither hash to 0x00, we get 0% sampling!
```

**Code**:
```c
static bool should_sample_alloc_page_hash(void *real_ptr, size_t size) {
    uintptr_t addr = (uintptr_t)real_ptr;
    uintptr_t page = addr >> 12;  // Extract page number (4KB pages)
    
    uint64_t h = hash64(page);
    return (h & 0xFF) == 0;  // Sample if page hash matches
}
```

**Why it fails on small working sets**:
- If app uses only 11 pages, probability none are sampled = (255/256)^11 ≈ 95.8%
- We observed exactly this: 11 unique pages, 0 sampled → 0% sampling rate

---

### 3.4 HYBRID: Small Poisson, Large Hash

**Principle**: Use Poisson for small allocations, hash for large allocations.

```
┌─────────────────────────────────────────────────────────────┐
│  Allocation Decision Tree                                   │
│                                                              │
│  if (size < 256 bytes) {                                    │
│      ┌──────────────────────────────────────┐               │
│      │ Use POISSON_HEADER                   │               │
│      │ • Decrement bytes_until_next          │               │
│      │ • Sample when counter <= 0           │               │
│      │ • Good for small, frequent allocs     │               │
│      └──────────────────────────────────────┘               │
│  } else {                                                   │
│      ┌──────────────────────────────────────┐               │
│      │ Use STATELESS_HASH                    │               │
│      │ • Hash the address                    │               │
│      │ • Sample if hash & 0xFF == 0          │               │
│      │ • Low overhead for large allocs       │               │
│      └──────────────────────────────────────┘               │
│  }                                                           │
└─────────────────────────────────────────────────────────────┘
```

**Visual Example**:

```
Allocations:
┌──────────┬──────────┬──────────┬──────────┬──────────┐
│ 100 bytes│ 500 bytes│ 50 bytes │ 1024 bytes│ 200 bytes│
│ < 256    │ >= 256   │ < 256    │ >= 256    │ < 256    │
│          │          │          │           │          │
│ POISSON  │ HASH     │ POISSON  │ HASH      │ POISSON  │
│ (counter)│ (address)│ (counter)│ (address) │ (counter)│
└──────────┴──────────┴──────────┴──────────┴──────────┘
```

**Code**:
```c
case SCHEME_HYBRID_SMALL_POISSON_LARGE_HASH:
    if (size < 256) {
        return should_sample_alloc_poisson(size);  // Poisson
    } else {
        return should_sample_alloc_hash(ptr);      // Hash
    }
```

---

## 4. Complete Flow: malloc() Interception

```
┌─────────────────────────────────────────────────────────────┐
│  Application: ptr = malloc(100);                            │
└────────────────────┬───────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│  Our malloc() wrapper (libsampler.so)                     │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 1. Check if initialized                                │  │
│  │    if (!g_initialized) init_sampler();                │  │
│  └──────────────────────────────────────────────────────┘  │
│                     │                                        │
│                     ▼                                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 2. Allocate with header                                │  │
│  │    total_size = 100 + 16 = 116                         │  │
│  │    real_ptr = real_malloc(116);                        │  │
│  └──────────────────────────────────────────────────────┘  │
│                     │                                        │
│                     ▼                                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 3. Initialize header                                   │  │
│  │    header->magic = SAMPLE_MAGIC;                      │  │
│  │    header->reserved = 100;                            │  │
│  └──────────────────────────────────────────────────────┘  │
│                     │                                        │
│                     ▼                                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 4. Decide: Sample or not?                             │  │
│  │    is_sampled = should_sample(real_ptr, 100);         │  │
│  │    ┌──────────────────────────────────────────────┐   │  │
│  │    │ Based on scheme:                              │   │  │
│  │    │ • STATELESS_HASH: hash address                │   │  │
│  │    │ • POISSON_HEADER: decrement counter           │   │  │
│  │    │ • PAGE_HASH: hash page number                 │   │  │
│  │    │ • HYBRID: size < 256 ? Poisson : Hash         │   │  │
│  │    └──────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────┘  │
│                     │                                        │
│                     ▼                                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 5. Set sampling flag                                  │  │
│  │    header->flags = is_sampled ? FLAG_SAMPLED : 0;    │  │
│  └──────────────────────────────────────────────────────┘  │
│                     │                                        │
│                     ▼                                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 6. Update statistics                                   │  │
│  │    update_stats_alloc(100, is_sampled);               │  │
│  │    • Increment total_allocs                           │  │
│  │    • If sampled: increment sampled_allocs             │  │
│  │    • Update dead-zone window tracking                 │  │
│  └──────────────────────────────────────────────────────┘  │
│                     │                                        │
│                     ▼                                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 7. Return user pointer                                 │  │
│  │    user_ptr = real_ptr + 16;                         │  │
│  │    return user_ptr;                                    │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────┬───────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│  Application receives: ptr (points to user's 100 bytes)    │
└─────────────────────────────────────────────────────────────┘
```

---

## 5. Special Case: realloc() with Foreign Pointers

**Problem**: What if `realloc()` receives a pointer NOT allocated by us?

```
┌─────────────────────────────────────────────────────────────┐
│  Application:                                                │
│    ptr1 = malloc(100);        // Our wrapper                │
│    ptr2 = some_library_func(); // Returns foreign pointer   │
│    ptr3 = realloc(ptr2, 200);  // Foreign pointer!          │
└────────────────────┬───────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│  Our realloc() wrapper                                       │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 1. Check if pointer is ours                             │  │
│  │    header = (SampleHeader *)(ptr - 16);                 │  │
│  │    if (header->magic != SAMPLE_MAGIC) {                │  │
│  │        // FOREIGN POINTER!                              │  │
│  │    }                                                     │  │
│  └──────────────────────────────────────────────────────┘  │
│                     │                                        │
│                     ▼                                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 2. Get size of foreign block                           │  │
│  │    size = malloc_usable_size(ptr);  // GNU extension   │  │
│  └──────────────────────────────────────────────────────┘  │
│                     │                                        │
│                     ▼                                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 3. Allocate NEW wrapped block                           │  │
│  │    new_ptr = our_malloc(200);  // Wrapped              │  │
│  └──────────────────────────────────────────────────────┘  │
│                     │                                        │
│                     ▼                                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 4. Copy data from old to new                           │  │
│  │    memcpy(new_ptr, ptr, min(size, 200));               │  │
│  └──────────────────────────────────────────────────────┘  │
│                     │                                        │
│                     ▼                                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 5. Free old foreign pointer                            │  │
│  │    real_free(ptr);  // Direct call to glibc            │  │
│  └──────────────────────────────────────────────────────┘  │
│                     │                                        │
│                     ▼                                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 6. Return new wrapped pointer                           │  │
│  │    return new_ptr;  // Now properly wrapped             │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

**Why this matters**: Ensures ALL pointers returned by our `realloc()` are properly wrapped, even if the input was foreign.

---

## 6. Statistics Collection

### 6.1 Global Statistics (Atomic)

```c
typedef struct Stats {
    uint64_t total_allocs;        // All allocations
    uint64_t sampled_allocs;      // Only sampled ones
    uint64_t total_bytes_alloc;
    uint64_t sampled_bytes_alloc;
    uint64_t windows_zero_sampled; // Dead-zone metric
    // ... more fields ...
} Stats;

static Stats g_stats = {0};  // Global, uses atomic operations
```

### 6.2 Dead Zone Tracking

Tracks windows of 100,000 allocations where zero samples occurred:

```
Allocations:  [1...100000] [100001...200000] [200001...300000]
Samples:      [✓✓✗✓...]    [✗✗✗✗...]        [✓✗✓✓...]
              (5 samples)   (0 samples!)      (3 samples)

Windows:      Window 1      Window 2         Window 3
              windows_zero_sampled = 1        (not zero)
```

**Code**:
```c
static void update_stats_alloc(size_t size, bool sampled) {
    atomic_fetch_add(&g_stats.total_allocs, 1);
    if (sampled) {
        atomic_fetch_add(&g_stats.sampled_allocs, 1);
        atomic_fetch_add(&g_stats.window_sampled_count, 1);
    }
    
    // Check window boundary
    uint64_t prev = atomic_fetch_add(&g_stats.window_alloc_count, 1);
    if ((prev + 1) % WINDOW_SIZE == 0) {
        uint64_t samples = atomic_exchange(&g_stats.window_sampled_count, 0);
        atomic_fetch_add(&g_stats.windows_total, 1);
        if (samples == 0) {
            atomic_fetch_add(&g_stats.windows_zero_sampled, 1);  // Dead zone!
        }
    }
}
```

---

## 7. Summary: Key Differences

| Scheme | State | Decision Basis | Address Reuse Bias | Sample Rate |
|--------|-------|----------------|-------------------|-------------|
| **STATELESS_HASH** | None | Address hash | Vulnerable | ~0.4% allocs |
| **POISSON_HEADER** | Thread-local counter | Bytes allocated | Immune | ~40% bytes |
| **PAGE_HASH** | None | Page number hash | Vulnerable (small sets) | ~0.4% pages |
| **HYBRID** | Thread-local (small) | Size-dependent | Moderate | Mixed |

---

## 8. Visual Comparison: Address Reuse Scenario

Imagine an application that repeatedly allocates/frees the same 100 addresses:

### STATELESS_HASH:
```
Address 0x1000: hash = 0x...d4  →  Never sampled ✗
Address 0x2000: hash = 0x...00  →  Always sampled ✓
Address 0x3000: hash = 0x...a1  →  Never sampled ✗
...
Result: Only 1 out of 100 addresses ever sampled (biased!)
```

### POISSON_HEADER:
```
Address 0x1000: allocated 1000 bytes → counter -= 1000
Address 0x2000: allocated 2000 bytes → counter -= 2000, hits 0 → SAMPLE ✓
Address 0x3000: allocated 500 bytes  → counter reset, -= 500
...
Result: Samples based on bytes, not addresses (unbiased!)
```

### PAGE_HASH:
```
Page 0x1000: hash = 0x...00  →  All allocs on this page sampled ✓
Page 0x2000: hash = 0x...d4  →  All allocs on this page NOT sampled ✗
...
Result: If all 100 addresses are on page 0x2000, 0% sampling!
```

---

This visual explanation should help you understand how the interception works and how each sampling scheme makes its decisions!



