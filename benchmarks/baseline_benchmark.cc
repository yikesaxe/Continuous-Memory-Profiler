// Baseline Memory Allocation Benchmark
// Purpose: Establish clean execution time without any profiling
// This will be our reference point for overhead measurements

#include <iostream>
#include <vector>
#include <random>
#include <chrono>
#include <iomanip>
#include <cstdlib>
#include <unistd.h>

// Configuration
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
        
        // Allocate
        for (size_t i = 0; i < ALLOCS_PER_ITERATION; ++i) {
            size_t size = size_dist(rng);
            void* ptr = malloc(size);
            if (ptr) {
                allocations.push_back(ptr);
            }
        }
        
        // Free
        for (void* ptr : allocations) {
            free(ptr);
        }
    }
}

void print_results(const char* test_name, double total_ns, size_t num_ops) {
    double total_ms = total_ns / 1'000'000.0;
    double ns_per_op = total_ns / num_ops;
    double us_per_op = ns_per_op / 1'000.0;
    
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
    std::cout << "║  Operations/sec:     " << std::setw(25) << std::fixed 
              << std::setprecision(0) << (num_ops / (total_ms / 1000.0)) << "  ║\n";
    std::cout << "╚════════════════════════════════════════════════════╝\n";
}

void print_production_estimate(double ns_per_alloc) {
    // Production scenario: 500M allocations per minute
    constexpr double PROD_ALLOCS_PER_MIN = 500'000'000.0;
    constexpr double PROD_ALLOCS_PER_SEC = PROD_ALLOCS_PER_MIN / 60.0;
    
    double cpu_ns_per_sec = ns_per_alloc * PROD_ALLOCS_PER_SEC;
    double cpu_seconds_per_sec = cpu_ns_per_sec / 1e9;
    double cpu_percent = cpu_seconds_per_sec * 100.0;
    
    std::cout << "\n╔════════════════════════════════════════════════════╗\n";
    std::cout << "║  Baseline Cost at Production Scale                ║\n";
    std::cout << "╠════════════════════════════════════════════════════╣\n";
    std::cout << "║  Allocation rate:    " << std::setw(20) 
              << "500M allocs/min   ║\n";
    std::cout << "║  Time per alloc:     " << std::setw(20) << std::fixed 
              << std::setprecision(1) << ns_per_alloc << " ns   ║\n";
    std::cout << "║  Baseline CPU cost:  " << std::setw(20) << std::fixed 
              << std::setprecision(2) << cpu_percent << " %    ║\n";
    std::cout << "╠════════════════════════════════════════════════════╣\n";
    std::cout << "║  ℹ️  This is the BASELINE allocation cost.         ║\n";
    std::cout << "║  Profiling overhead will be ADDITIONAL to this.    ║\n";
    std::cout << "║                                                    ║\n";
    std::cout << "║  Acceptable profiling overhead: < 5% additional    ║\n";
    std::cout << "║  Target: < " << std::setw(6) << std::fixed << std::setprecision(1)
              << (ns_per_alloc * 0.05) << " ns extra per allocation     ║\n";
    std::cout << "╚════════════════════════════════════════════════════╝\n";
}

int main() {
    std::cout << "\n";
    std::cout << "══════════════════════════════════════════════════════\n";
    std::cout << "  BASELINE MEMORY ALLOCATION BENCHMARK\n";
    std::cout << "  No profiling - establishing reference performance\n";
    std::cout << "══════════════════════════════════════════════════════\n";
    std::cout << "\nConfiguration:\n";
    std::cout << "  Iterations:          " << NUM_ITERATIONS << "\n";
    std::cout << "  Allocs per iteration: " << ALLOCS_PER_ITERATION << "\n";
    std::cout << "  Total allocations:    " << TOTAL_ALLOCATIONS << "\n";
    std::cout << "  Allocation size:      " << MIN_ALLOC_SIZE << "-" 
              << MAX_ALLOC_SIZE << " bytes\n";
    std::cout << "\nAllocator: ";
    
#ifdef USE_TCMALLOC
    std::cout << "TCMalloc (google-perftools)\n";
#else
    std::cout << "System default (glibc)\n";
#endif
    
    std::cout << "\n⚠️  For eBPF tracing, attach now!\n";
    std::cout << "PID: " << getpid() << "\n";
    std::cout << "\nPress Enter to start (or Ctrl-C to cancel)...\n";
    std::cin.get();
    
    std::cout << "\n🏃 Running workload...\n";
    
    BenchmarkTimer timer;
    run_allocation_workload();
    double elapsed = timer.elapsed_ns();
    
    print_results("Baseline Performance", elapsed, TOTAL_ALLOCATIONS);
    
    double ns_per_alloc = elapsed / TOTAL_ALLOCATIONS;
    print_production_estimate(ns_per_alloc);
    
    // Machine-readable output
    std::cout << "\nMACHINE_READABLE_RESULT:\n";
    std::cout << "TOTAL_NS=" << std::fixed << std::setprecision(0) << elapsed << "\n";
    std::cout << "NS_PER_ALLOC=" << std::fixed << std::setprecision(2) << ns_per_alloc << "\n";
    std::cout << "TOTAL_ALLOCS=" << TOTAL_ALLOCATIONS << "\n";
    
    return 0;
}