# Quick Reference: Measuring Sampling Overhead

## 🚀 TL;DR - Run Everything

```bash
cd /home/axel/Workspace/Continous-Memory-Profiler/stateless-sampling/bench

# Run all benchmarks
./run_timed_benchmarks.sh

# View summary
./summarize_timing.sh
```

---

## 📊 Two Approaches

### 1. Microbenchmark (Isolated)
**What:** Pure sampling decision logic, no real malloc  
**When:** Compare raw algorithmic overhead  

```bash
./bench_sampling_overhead 1000000
```

### 2. Real Workload (Realistic)
**What:** Actual allocation patterns with timed sampler  
**When:** Measure overhead in realistic conditions  

```bash
export SAMPLER_TIMING=1
export SAMPLER_SCHEME=COMBINED
export LD_PRELOAD="../sampler/libsampler_timed.so"
./bench_alloc_patterns 1 100000 64 4096 > /dev/null
```

---

## 📝 Single Test Template

```bash
# Setup
export SAMPLER_TIMING=1
export LD_PRELOAD="../sampler/libsampler_timed.so"

# Choose scheme: POISSON, STATELESS_HASH, or COMBINED
export SAMPLER_SCHEME=POISSON

# Run workload (timing printed to stderr at exit)
./bench_alloc_patterns <mode> <args...> > /dev/null 2> timing.txt

# View results
cat timing.txt
```

---

## 🎯 Workload Quick Reference

| Mode | Command | Description |
|------|---------|-------------|
| **1** | `./bench 1 100000 64 4096` | Monotonic heap (95% freed, 5% leaked) |
| **2** | `./bench 2 1000 1000 64 4096 50` | Steady state pool (random churn) |
| **4** | `./bench 4 500 100000 64 4096` | High address reuse (tests hash bias) |

---

## 🔧 Environment Variables

| Variable | Values | Default | Purpose |
|----------|--------|---------|---------|
| `SAMPLER_TIMING` | `0` or `1` | `0` | Enable timing measurements |
| `SAMPLER_SCHEME` | `POISSON`, `STATELESS_HASH`, `COMBINED`, `NONE` | `NONE` | Sampling strategy |
| `SAMPLER_POISSON_MEAN_BYTES` | `1024`, `4096`, `8192`, etc. | `4096` | Poisson sampling rate |
| `LD_PRELOAD` | Path to `.so` | - | Preload sampler library |

---

## 📈 Expected Results (ARM64)

| Workload | Poisson (cycles/decision) | Hash (cycles/decision) | Speedup |
|----------|---------------------------|------------------------|---------|
| Microbench (64B) | 0.04 | 0.01 | **3.5x** |
| Microbench (4KB) | 0.72 | 0.01 | **62x** |
| Real: Monotonic | 0.2-0.4 | 0.01-0.02 | **15-25x** |
| Real: Steady | 0.3-0.5 | 0.01-0.02 | **20-35x** |
| Real: Reuse | 0.1-0.3 | 0.01-0.02 | **10-20x** |

*Note: Results vary based on allocation patterns and sizes*

---

## 🎓 Key Takeaways

1. **Hash is 3-62x faster** than Poisson for sampling decisions
2. **Speedup increases** with larger allocations and higher sample rates
3. **Real workload overhead** is higher than microbenchmark (cache, syscalls)
4. **Combined mode** measures both schemes on identical workload for fair comparison

---

## ⚡ Common Commands

```bash
# Quick microbenchmark test
./bench_sampling_overhead 100000

# Test specific workload with both schemes
export SAMPLER_TIMING=1 SAMPLER_SCHEME=COMBINED LD_PRELOAD="../sampler/libsampler_timed.so"
./bench_alloc_patterns 1 50000 64 4096 > /dev/null

# Run your real application with timing
export SAMPLER_TIMING=1 SAMPLER_SCHEME=COMBINED LD_PRELOAD="/path/to/libsampler_timed.so"
./your_app

# Compare results side-by-side
./summarize_timing.sh
```

---

## 📚 Documentation

- **TIMING_BENCHMARK_GUIDE.md** - Full guide with detailed explanations
- **SAMPLING_OVERHEAD_RESULTS.md** - Microbenchmark results and analysis
- **timing_*.txt** - Generated result files from runs

---

## 🐛 Troubleshooting One-Liners

```bash
# Check if timed sampler exists
ls -lh ../sampler/libsampler_timed.so

# Rebuild everything
make clean && make all && cd ../sampler && make clean && make all && cd ../bench

# Verify env vars are set
env | grep SAMPLER

# Test without LD_PRELOAD (runs without sampling)
unset LD_PRELOAD
./bench_alloc_patterns 1 1000 64 256
```
