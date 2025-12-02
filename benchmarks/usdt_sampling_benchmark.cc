// Test Case 3b: USDT on SAMPLING PATH only
// The optimal strategy - low overhead!

#include <iostream>
#include <vector>
#include <random>
#include <chrono>
#include <iomanip>
#include <cstdlib>
#include <unistd.h>
#include <sys/sdt.h>

// Configuration
constexpr size_t NUM_ITERATIONS = 10000;
constexpr size_t ALLOCS_PER_ITERATION = 1000;
constexpr size_t TOTAL_ALLOCATIONS = NUM_ITERATIONS * ALLOCS_PER_ITERATION;
constexpr size_t MIN_ALLOC_SIZE = 16;
constexpr size_t MAX_ALLOC_SIZE = 4096;

// Sampling configuration
constexpr size_t SAMPLE_THRESHOLD_BYTES = 512 * 1024;  // Sample every 512KB allocated

// Per-thread sampling state
thread_local size_t bytes_until_sample = SAMPLE_THRESHOLD_BYTES;
thread_local size_t total_samples = 0;

class BenchmarkTimer {
    using Clock = std::chrono::high_resolution_clock;
    using TimePoint = Clock::time_point;
    TimePoint start_;
public:
    BenchmarkTimer() : start_(Clock::now()) {}
    void reset() { start_ = Clock::now(); }
    double elapsed_ns() const {
        return std::chrono::duration<double, std::nano>(Clock::now() - start_).count();
    }
};

// Optimized malloc with sampling
void* tracked_malloc(size_t size) {
    void* ptr = malloc(size);
    
    // Fast path: cheap integer comparison only
    if (bytes_until_sample > size) {
        bytes_until_sample -= size;
        return ptr;  // No probe fired! ✅
    }
    
    // Sampling path: USDT probe fires only here (rare!)
    bytes_until_sample = SAMPLE_THRESHOLD_BYTES;
    total_samples++;
    
    DTRACE_PROBE3(memory_profiler, sample_alloc, size, ptr, total_samples);
    
    return ptr;
}

void tracked_free(void* ptr) {
    free(ptr);
    // No probe on free to keep it fast
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

void print_results(const char* test_name, double total_ns, size_t num_ops, 
                   double baseline_ns, size_t samples) {
    double ns_per_op = total_ns / num_ops;
    double overhead_ns = ns_per_op - baseline_ns;
    double overhead_mult = ns_per_op / baseline_ns;
    double sample_rate = static_cast<double>(num_ops) / samples;
    
    std::cout << "\n╔════════════════════════════════════════════════════╗\n";
    std::cout << "║  " << std::left << std::setw(47) << test_name << "║\n";
    std::cout << "╠════════════════════════════════════════════════════╣\n";
    std::cout << "║  Total allocations:  " << std::right << std::setw(25) 
              << num_ops << "  ║\n";
    std::cout << "║  Samples taken:      " << std::setw(25) 
              << samples << "  ║\n";
    std::cout << "║  Sample rate:        1 in " << std::setw(19) 
              << std::fixed << std::setprecision(0) << sample_rate << "  ║\n";
    std::cout << "║  Total time:         " << std::setw(20) << std::fixed 
              << std::setprecision(2) << (total_ns / 1e6) << " ms   ║\n";
    std::cout << "║  Time per operation: " << std::setw(20) << std::fixed 
              << std::setprecision(1) << ns_per_op << " ns   ║\n";
    std::cout << "╠════════════════════════════════════════════════════╣\n";
    std::cout << "║  Baseline:           " << std::setw(20) << std::fixed 
              << std::setprecision(1) << baseline_ns << " ns   ║\n";
    std::cout << "║  Sampling overhead:  " << std::setw(20) << std::fixed 
              << std::setprecision(1) << overhead_ns << " ns   ║\n";
    std::cout << "║  Slowdown:           " << std::setw(20) << std::fixed 
              << std::setprecision(2) << overhead_mult << "x       ║\n";
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
              << std::setprecision(2) << cpu_percent << " %    ║\n";
    std::cout << "╠════════════════════════════════════════════════════╣\n";
    
    if (cpu_percent < 2.0) {
        std::cout << "║  Verdict:            ✅ EXCELLENT - Production Ready!║\n";
    } else if (cpu_percent < 5.0) {
        std::cout << "║  Verdict:            ✅ GOOD - Acceptable overhead  ║\n";
    } else if (cpu_percent < 10.0) {
        std::cout << "║  Verdict:            ⚠️  BORDERLINE                 ║\n";
    } else {
        std::cout << "║  Verdict:            ❌ TOO EXPENSIVE               ║\n";
    }
    std::cout << "╚════════════════════════════════════════════════════╝\n";
}

int main() {
    constexpr double BASELINE_NS = 12.6;
    
    std::cout << "\n══════════════════════════════════════════════════════\n";
    std::cout << "  TEST CASE 3b: USDT on SAMPLING PATH Only\n";
    std::cout << "  (The optimal strategy!)\n";
    std::cout << "══════════════════════════════════════════════════════\n";
    std::cout << "\nConfiguration:\n";
    std::cout << "  Allocator:           TCMalloc\n";
    std::cout << "  Total allocations:   " << TOTAL_ALLOCATIONS << "\n";
    std::cout << "  Baseline:            " << BASELINE_NS << " ns\n";
    std::cout << "  Sample threshold:    " << SAMPLE_THRESHOLD_BYTES << " bytes\n";
    std::cout << "  USDT probes:         ON SAMPLING PATH ONLY\n";
    
    std::cout << "\n⚠️  You can optionally attach a tracer:\n";
    std::cout << "  sudo python3 trace_usdt_sampling.py -p " << getpid() << "\n";
    std::cout << "\nPress Enter to start...\n";
    std::cin.get();
    
    std::cout << "\n🏃 Running workload with optimized sampling...\n";
    
    BenchmarkTimer timer;
    run_allocation_workload();
    double elapsed = timer.elapsed_ns();
    
    print_results("USDT Sampling Path Only", elapsed, TOTAL_ALLOCATIONS, 
                  BASELINE_NS, total_samples);
    print_production_impact(elapsed / TOTAL_ALLOCATIONS, BASELINE_NS);
    
    std::cout << "\nMACHINE_READABLE_RESULT:\n";
    std::cout << "TOTAL_NS=" << std::fixed << std::setprecision(0) << elapsed << "\n";
    std::cout << "NS_PER_ALLOC=" << std::fixed << std::setprecision(2) 
              << (elapsed / TOTAL_ALLOCATIONS) << "\n";
    std::cout << "SAMPLES=" << total_samples << "\n";
    std::cout << "BASELINE_NS=" << BASELINE_NS << "\n";
    
    return 0;
}