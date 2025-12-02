CXX = g++
CXXFLAGS = -std=c++17 -O2 -Wall -Wextra
LDFLAGS = -lpthread

# TCMalloc linking
TCMALLOC_LDFLAGS = -ltcmalloc_minimal

# USDT support flags
USDT_FLAGS = -I/usr/include/aarch64-linux-gnu

# LD_PRELOAD wrapper flags
CC = gcc
WRAPPER_FLAGS = -shared -fPIC

.PHONY: all clean test help

all: baseline_benchmark baseline_benchmark_tcmalloc uprobe_benchmark uprobe_benchmark_glibc usdt_every_alloc_benchmark usdt_sampling_benchmark malloc_wrapper.so
# Baseline with default allocator (glibc)
baseline_benchmark: baseline_benchmark.cc
	$(CXX) $(CXXFLAGS) -o $@ $< $(LDFLAGS)

# Test Case 2: UProbe benchmark (high overhead)
uprobe_benchmark: uprobe_benchmark.cc
	$(CXX) $(CXXFLAGS) -DUSE_TCMALLOC -o $@ $< $(LDFLAGS) $(TCMALLOC_LDFLAGS)

# Test Case 2: UProbe benchmark with glibc (so UProbe works)
uprobe_benchmark_glibc: uprobe_benchmark.cc
	$(CXX) $(CXXFLAGS) -o $@ $< $(LDFLAGS)

# Baseline with TCMalloc
baseline_benchmark_tcmalloc: baseline_benchmark.cc
	$(CXX) $(CXXFLAGS) -DUSE_TCMALLOC -o $@ $< $(LDFLAGS) $(TCMALLOC_LDFLAGS)

# Test Case 3a: USDT on every allocation
usdt_every_alloc_benchmark: usdt_every_alloc_benchmark.cc
	$(CXX) $(CXXFLAGS) $(USDT_FLAGS) -DUSE_TCMALLOC -o $@ $< $(LDFLAGS) $(TCMALLOC_LDFLAGS)

# Test Case 3b: USDT on sampling path only
usdt_sampling_benchmark: usdt_sampling_benchmark.cc
	$(CXX) $(CXXFLAGS) $(USDT_FLAGS) -DUSE_TCMALLOC -o $@ $< $(LDFLAGS) $(TCMALLOC_LDFLAGS)

# LD_PRELOAD wrapper with USDT probes (works with ANY binary!)
malloc_wrapper.so: malloc_wrapper.c
	$(CC) $(WRAPPER_FLAGS) $(USDT_FLAGS) -o $@ $< -ldl

test: baseline_benchmark baseline_benchmark_tcmalloc
	@echo "═══════════════════════════════════════════════════════"
	@echo "Testing with GLIBC allocator:"
	@echo "═══════════════════════════════════════════════════════"
	./baseline_benchmark
	@echo ""
	@echo "═══════════════════════════════════════════════════════"
	@echo "Testing with TCMalloc allocator:"
	@echo "═══════════════════════════════════════════════════════"
	./baseline_benchmark_tcmalloc

clean:
	rm -f baseline_benchmark baseline_benchmark_tcmalloc uprobe_benchmark uprobe_benchmark_glibc usdt_every_alloc_benchmark usdt_sampling_benchmark malloc_wrapper.so *.o

help:
	@echo "eBPF Memory Profiling Benchmarks - Baseline Test"
	@echo ""
	@echo "Targets:"
	@echo "  all       - Build both glibc and TCMalloc versions"
	@echo "  test      - Run both versions and compare"
	@echo "  clean     - Remove built files"
	@echo "  help      - Show this message"
	@echo ""
	@echo "Prerequisites:"
	@echo "  sudo apt-get install -y libtcmalloc-minimal4 libgoogle-perftools-dev"
	@echo ""
	@echo "Usage:"
	@echo "  make           # Build"
	@echo "  make test      # Run benchmarks"
	@echo "  ./baseline_benchmark              # Run with glibc"
	@echo "  ./baseline_benchmark_tcmalloc     # Run with TCMalloc"