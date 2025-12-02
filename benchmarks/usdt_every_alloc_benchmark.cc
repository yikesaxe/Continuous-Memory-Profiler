// Test Case 3a: USDT on EVERY allocation
// Shows that even USDT is too expensive without sampling

#include <iostream>
#include <vector>
#include <random>
#include <chrono>
#include <iomanip>
#include <cstdlib>
#include <unistd.h>
#include <sys/sdt.h>  // USDT support

// Configuration
constexpr size_t NUM_ITERATIONS = 10000;
constexpr size_t ALLOCS_PER_ITERATION = 1000;
constexpr size_t TOTAL_ALLOCATIONS = NUM_ITERATIONS * ALLOCS_PER_ITERATION;
constexpr size_t MIN_ALLOC_SIZE = 16;
constexpr size_t MAX_ALLOC_SIZE = 4096;

class BenchmarkTimer {
    using Clock = std::chrono::high_resolution_clock;
    using TimePoint = Clock::time_point;  // ← Move this BEFORE using it
    TimePoint start_;
public:
    BenchmarkTimer() : start_(Clock::now()) {}
    void reset() { start_ = Clock::now(); }
    double elapsed_ns() const {
        return std::chrono::duration<double, std::nano>(Clock::now() - start_).count();
    }
};

// Instrumented malloc - USDT probe fires on EVERY allocation
void* tracked_malloc(size_t size) {
    void* ptr = malloc(size);
    
    // USDT probe - fires EVERY time!
    // When not being traced: ~0-2 ns (NOP)
    // When being traced: ~500-800 ns
    DTRACE_PROBE2(memory_profiler, malloc_every, size, ptr);
    
    return ptr;
}

void tracked_free(void* ptr) {
    DTRACE_PROBE1(memory_profiler, free_every, ptr);
    free(ptr);
}

void run_allocation_workload() {
    std::mt19937 rng(std::random_device{}());
    std::uniform_int_distribution<size_t> size_dist(MIN_ALLOC_SIZE, MAX_ALLOC_SIZE);
    
    for (size_t iter = 0; iter < NUM_ITERATIONS; ++iter) {
        std::vector<void*> allocations;
        allocations.reserve(ALLOCS_PER_ITERATION);
        
        for (size_t i = 0; i < ALLOCS_PER_ITERATION; ++i) {
            size_t size = size_dist(rng);
            void* ptr = tracked_malloc(size);
            if (ptr) {
                allocations.push_back(ptr);
            }
        }
        
        for (void* ptr : allocations) {
            tracked_free(ptr);
        }
    }
}

void print_results(const char* test_name, double total_ns, size_t num_ops, double baseline_ns) {
    double ns_per_op = total_ns / num_ops;
    double overhead_ns = ns_per_op - baseline_ns;
    double overhead_mult = ns_per_op / baseline_ns;
    
    std::cout << "\n╔════════════════════════════════════════════════════╗\n";
    std::cout << "║  " << std::left << std::setw(47) << test_name << "║\n";
    std::cout << "╠════════════════════════════════════════════════════╣\n";
    std::cout << "║  Total operations:   " << std::right << std::setw(25) 
              << num_ops << "  ║\n";
    std::cout << "║  Total time:         " << std::setw(20) << std::fixed 
              << std::setprecision(2) << (total_ns / 1e6) << " ms   ║\n";
    std::cout << "║  Time per operation: " << std::setw(20) << std::fixed 
              << std::setprecision(1) << ns_per_op << " ns   ║\n";
    std::cout << "╠════════════════════════════════════════════════════╣\n";
    std::cout << "║  Baseline:           " << std::setw(20) << std::fixed 
              << std::setprecision(1) << baseline_ns << " ns   ║\n";
    std::cout << "║  USDT overhead:      " << std::setw(20) << std::fixed 
              << std::setprecision(1) << overhead_ns << " ns   ║\n";
    std::cout << "║  Slowdown:           " << std::setw(20) << std::fixed 
              << std::setprecision(1) << overhead_mult << "x       ║\n";
    std::cout << "╚════════════════════════════════════════════════════╝\n";
}

void print_production_impact(double ns_per_alloc, double baseline_ns) {
    constexpr double PROD_ALLOCS_PER_SEC = 500'000'000.0 / 60.0;
    double overhead_ns = ns_per_alloc - baseline_ns;
    double cpu_percent = (overhead_ns * PROD_ALLOCS_PER_SEC) / 1e9 * 100.0;
    
    std::cout << "\n╔════════════════════════════════════════════════════╗\n";
    std::cout << "║  Production Impact (500M allocs/min)               ║\n";
    std::cout << "╠════════════════════════════════════════════════════╣\n";
    std::cout << "║  Profiling overhead: " << std::setw(20) << std::fixed 
              << std::setprecision(1) << overhead_ns << " ns   ║\n";
    std::cout << "║  Extra CPU cost:     " << std::setw(20) << std::fixed 
              << std::setprecision(1) << cpu_percent << " %    ║\n";
    std::cout << "╠════════════════════════════════════════════════════╣\n";
    
    if (cpu_percent < 2.0) {
        std::cout << "║  Verdict:            ✅ EXCELLENT (< 2%)            ║\n";
    } else if (cpu_percent < 5.0) {
        std::cout << "║  Verdict:            ✅ GOOD (< 5%)                 ║\n";
    } else if (cpu_percent < 10.0) {
        std::cout << "║  Verdict:            ⚠️  ACCEPTABLE (< 10%)         ║\n";
    } else {
        std::cout << "║  Verdict:            ❌ TOO EXPENSIVE               ║\n";
    }
    std::cout << "╚════════════════════════════════════════════════════╝\n";
}

int main() {
    constexpr double BASELINE_NS = 12.6;  // TCMalloc baseline
    
    std::cout << "\n══════════════════════════════════════════════════════\n";
    std::cout << "  TEST CASE 3a: USDT on EVERY Allocation\n";
    std::cout << "  (No sampling - still expensive!)\n";
    std::cout << "══════════════════════════════════════════════════════\n";
    std::cout << "\nConfiguration:\n";
    std::cout << "  Allocator:           TCMalloc\n";
    std::cout << "  Total allocations:   " << TOTAL_ALLOCATIONS << "\n";
    std::cout << "  Baseline:            " << BASELINE_NS << " ns\n";
    std::cout << "  USDT probes:         ON EVERY ALLOCATION\n";
    
    std::cout << "\n⚠️  You can optionally attach a tracer:\n";
    std::cout << "  sudo python3 trace_usdt_every.py -p " << getpid() << "\n";
    std::cout << "\nPress Enter to start (with or without tracer)...\n";
    std::cin.get();
    
    std::cout << "\n🏃 Running workload...\n";
    
    BenchmarkTimer timer;
    run_allocation_workload();
    double elapsed = timer.elapsed_ns();
    
    print_results("USDT on Every Allocation", elapsed, TOTAL_ALLOCATIONS, BASELINE_NS);
    print_production_impact(elapsed / TOTAL_ALLOCATIONS, BASELINE_NS);
    
    std::cout << "\nMACHINE_READABLE_RESULT:\n";
    std::cout << "TOTAL_NS=" << std::fixed << std::setprecision(0) << elapsed << "\n";
    std::cout << "NS_PER_ALLOC=" << std::fixed << std::setprecision(2) 
              << (elapsed / TOTAL_ALLOCATIONS) << "\n";
    std::cout << "BASELINE_NS=" << BASELINE_NS << "\n";
    
    return 0;
}