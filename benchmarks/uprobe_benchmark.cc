// Test Case 2: High-Overhead UProbe Strategy
// Demonstrates that UProbes on every malloc are NOT viable for production

#include <iostream>
#include <vector>
#include <random>
#include <chrono>
#include <iomanip>
#include <cstdlib>
#include <unistd.h>

// Same configuration as baseline
constexpr size_t NUM_ITERATIONS = 10000;
constexpr size_t ALLOCS_PER_ITERATION = 1000;
constexpr size_t TOTAL_ALLOCATIONS = NUM_ITERATIONS * ALLOCS_PER_ITERATION;
constexpr size_t MIN_ALLOC_SIZE = 16;
constexpr size_t MAX_ALLOC_SIZE = 4096;

class BenchmarkTimer {
    using Clock = std::chrono::high_resolution_clock;
    using TimePoint = Clock::time_point;
    TimePoint start_;

public:
    BenchmarkTimer() : start_(Clock::now()) {}
    
    void reset() { start_ = Clock::now(); }
    
    double elapsed_ns() const {
        auto end = Clock::now();
        return std::chrono::duration<double, std::nano>(end - start_).count();
    }
    
    double elapsed_ms() const {
        return elapsed_ns() / 1'000'000.0;
    }
};

void run_allocation_workload() {
    std::mt19937 rng(std::random_device{}());
    std::uniform_int_distribution<size_t> size_dist(MIN_ALLOC_SIZE, MAX_ALLOC_SIZE);
    
    for (size_t iter = 0; iter < NUM_ITERATIONS; ++iter) {
        std::vector<void*> allocations;
        allocations.reserve(ALLOCS_PER_ITERATION);
        
        for (size_t i = 0; i < ALLOCS_PER_ITERATION; ++i) {
            size_t size = size_dist(rng);
            void* ptr = malloc(size);
            if (ptr) {
                allocations.push_back(ptr);
            }
        }
        
        for (void* ptr : allocations) {
            free(ptr);
        }
    }
}

void print_results(const char* test_name, double total_ns, size_t num_ops, double baseline_ns) {
    double total_ms = total_ns / 1'000'000.0;
    double ns_per_op = total_ns / num_ops;
    double us_per_op = ns_per_op / 1'000.0;
    double overhead_ns = ns_per_op - baseline_ns;
    double overhead_multiplier = ns_per_op / baseline_ns;
    
    std::cout << "\n╔════════════════════════════════════════════════════╗\n";
    std::cout << "║  " << std::left << std::setw(47) << test_name << "║\n";
    std::cout << "╠════════════════════════════════════════════════════╣\n";
    std::cout << "║  Total operations:   " << std::right << std::setw(25) 
              << num_ops << "  ║\n";
    std::cout << "║  Total time:         " << std::setw(20) << std::fixed 
              << std::setprecision(2) << total_ms << " ms   ║\n";
    std::cout << "║  Time per operation: " << std::setw(20) << std::fixed 
              << std::setprecision(1) << ns_per_op << " ns   ║\n";
    std::cout << "║                      " << std::setw(20) << std::fixed 
              << std::setprecision(3) << us_per_op << " μs   ║\n";
    std::cout << "╠════════════════════════════════════════════════════╣\n";
    std::cout << "║  Baseline (no probe):" << std::setw(20) << std::fixed 
              << std::setprecision(1) << baseline_ns << " ns   ║\n";
    std::cout << "║  UProbe overhead:    " << std::setw(20) << std::fixed 
              << std::setprecision(1) << overhead_ns << " ns   ║\n";
    std::cout << "║  Slowdown:           " << std::setw(20) << std::fixed 
              << std::setprecision(1) << overhead_multiplier << "x       ║\n";
    std::cout << "╚════════════════════════════════════════════════════╝\n";
}

void print_production_impact(double ns_per_alloc, double baseline_ns) {
    constexpr double PROD_ALLOCS_PER_MIN = 500'000'000.0;
    constexpr double PROD_ALLOCS_PER_SEC = PROD_ALLOCS_PER_MIN / 60.0;
    
    double overhead_ns = ns_per_alloc - baseline_ns;
    double cpu_ns_per_sec = overhead_ns * PROD_ALLOCS_PER_SEC;
    double cpu_seconds_per_sec = cpu_ns_per_sec / 1e9;
    double cpu_percent = cpu_seconds_per_sec * 100.0;
    double num_cores = cpu_seconds_per_sec;
    
    std::cout << "\n╔════════════════════════════════════════════════════╗\n";
    std::cout << "║  Production Impact Analysis (500M allocs/min)      ║\n";
    std::cout << "╠════════════════════════════════════════════════════╣\n";
    std::cout << "║  Profiling overhead: " << std::setw(20) << std::fixed 
              << std::setprecision(1) << overhead_ns << " ns   ║\n";
    std::cout << "║  Extra CPU per core: " << std::setw(20) << std::fixed 
              << std::setprecision(1) << cpu_percent << " %    ║\n";
    std::cout << "║  CPU cores consumed: " << std::setw(20) << std::fixed 
              << std::setprecision(2) << num_cores << "        ║\n";
    std::cout << "╠════════════════════════════════════════════════════╣\n";
    
    if (cpu_percent < 2.0) {
        std::cout << "║  Verdict:            ✅ EXCELLENT (< 2% overhead)   ║\n";
    } else if (cpu_percent < 5.0) {
        std::cout << "║  Verdict:            ✅ GOOD (< 5% overhead)        ║\n";
    } else if (cpu_percent < 10.0) {
        std::cout << "║  Verdict:            ⚠️  ACCEPTABLE (< 10% overhead)║\n";
    } else if (cpu_percent < 50.0) {
        std::cout << "║  Verdict:            ❌ TOO EXPENSIVE (> 10%)       ║\n";
    } else {
        std::cout << "║  Verdict:            ❌ COMPLETELY UNVIABLE         ║\n";
    }
    std::cout << "╚════════════════════════════════════════════════════╝\n";
}

int main() {
    // TCMalloc baseline from Test Case 1
    constexpr double BASELINE_NS = 12.6;
    
    std::cout << "\n";
    std::cout << "══════════════════════════════════════════════════════\n";
    std::cout << "  TEST CASE 2: HIGH-OVERHEAD STRATEGY\n";
    std::cout << "  UProbe on EVERY malloc call\n";
    std::cout << "══════════════════════════════════════════════════════\n";
    std::cout << "\nConfiguration:\n";
    std::cout << "  Iterations:           " << NUM_ITERATIONS << "\n";
    std::cout << "  Allocs per iteration: " << ALLOCS_PER_ITERATION << "\n";
    std::cout << "  Total allocations:    " << TOTAL_ALLOCATIONS << "\n";
    std::cout << "  Allocation size:      " << MIN_ALLOC_SIZE << "-" 
              << MAX_ALLOC_SIZE << " bytes\n";
    std::cout << "  Allocator:            TCMalloc\n";
    std::cout << "  Baseline (no probe):  " << BASELINE_NS << " ns\n";
    
    std::cout << "\n⚠️  IMPORTANT: Attach the eBPF UProbe tracer now!\n";
    std::cout << "\nIn another terminal, run:\n";
    std::cout << "  sudo python3 trace_malloc_uprobe.py -p " << getpid() << "\n";
    std::cout << "\nPress Enter when the tracer is attached and ready...\n";
    std::cin.get();
    
    std::cout << "\n🏃 Running workload with UProbe attached...\n";
    std::cout << "(This will be MUCH slower than baseline!)\n\n";
    
    BenchmarkTimer timer;
    run_allocation_workload();
    double elapsed = timer.elapsed_ns();
    
    print_results("UProbe on Every malloc()", elapsed, TOTAL_ALLOCATIONS, BASELINE_NS);
    
    double ns_per_alloc = elapsed / TOTAL_ALLOCATIONS;
    print_production_impact(ns_per_alloc, BASELINE_NS);
    
    std::cout << "\nMACHINE_READABLE_RESULT:\n";
    std::cout << "TOTAL_NS=" << std::fixed << std::setprecision(0) << elapsed << "\n";
    std::cout << "NS_PER_ALLOC=" << std::fixed << std::setprecision(2) << ns_per_alloc << "\n";
    std::cout << "BASELINE_NS=" << BASELINE_NS << "\n";
    std::cout << "OVERHEAD_NS=" << std::fixed << std::setprecision(2) 
              << (ns_per_alloc - BASELINE_NS) << "\n";
    std::cout << "TOTAL_ALLOCS=" << TOTAL_ALLOCATIONS << "\n";
    
    return 0;
}