#!/usr/bin/env python3
"""
eBPF USDT tracer for malloc_wrapper.so
Traces sampled allocations from the LD_PRELOAD wrapper

Usage:
    Terminal 1: LD_PRELOAD=./malloc_wrapper.so ./any_program
    Terminal 2: sudo python3 trace_malloc_wrapper.py -p <PID>
"""

from bcc import BPF, USDT
import argparse
import sys
import signal

bpf_text = """
#include <uapi/linux/ptrace.h>

BPF_ARRAY(total_samples, u64, 1);

int trace_sample_alloc(struct pt_regs *ctx) {
    // Just increment counter - don't collect detailed events
    // This avoids eBPF verifier complexity
    int zero = 0;
    u64 *count = total_samples.lookup(&zero);
    if (count) {
        (*count)++;
    }
    
    return 0;
}
"""

def main():
    parser = argparse.ArgumentParser(
        description="Trace malloc_wrapper.so USDT probes",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Attach to running process
  sudo python3 trace_malloc_wrapper.py -p 12345
  
  # Run a program with the wrapper
  LD_PRELOAD=./malloc_wrapper.so ./your_program &
  sudo python3 trace_malloc_wrapper.py -p $(pgrep your_program)
"""
    )
    parser.add_argument("-p", "--pid", type=int, required=True,
                       help="Process ID to trace")
    parser.add_argument("-v", "--verbose", action="store_true",
                       help="Show individual allocation events")
    args = parser.parse_args()

    print(f"╔════════════════════════════════════════════════════╗")
    print(f"║  malloc_wrapper.so USDT Tracer                     ║")
    print(f"╠════════════════════════════════════════════════════╣")
    print(f"║  PID: {args.pid:<44} ║")
    print(f"║  Provider: malloc_wrapper                          ║")
    print(f"║  Probe: sample_alloc                               ║")
    print(f"╚════════════════════════════════════════════════════╝")
    print()

    # Set up USDT
    print("Attaching USDT probes...")
    usdt = USDT(pid=args.pid)
    
    try:
        usdt.enable_probe(probe="sample_alloc", fn_name="trace_sample_alloc")
    except Exception as e:
        print(f"❌ Error: Could not attach USDT probe")
        print(f"   {e}")
        print()
        print("Common issues:")
        print("  1. Process not running with LD_PRELOAD=./malloc_wrapper.so")
        print("  2. malloc_wrapper.so not built with USDT support")
        print("  3. Wrong PID")
        print()
        print("Verify with: readelf -n malloc_wrapper.so | grep stapsdt")
        sys.exit(1)
    
    # Load eBPF program
    b = BPF(text=bpf_text, usdt_contexts=[usdt])
    
    print("✅ USDT probes attached successfully")
    print("📊 Counting sampled allocations... Press Ctrl-C to stop\n")
    print("(Simplified: just counting, not collecting full events)")
    
    def signal_handler(sig, frame):
        count = b["total_samples"][0].value
        print(f"\n\n╔════════════════════════════════════════════════════╗")
        print(f"║  Tracing Summary                                   ║")
        print(f"╠════════════════════════════════════════════════════╣")
        print(f"║  Total samples:      {count:>28,} ║")
        print(f"╚════════════════════════════════════════════════════╝")
        sys.exit(0)
    
    signal.signal(signal.SIGINT, signal_handler)

    # Just wait - we're only counting, not processing events
    try:
        import time
        while True:
            time.sleep(1)
            count = b["total_samples"][0].value
            print(f"Samples so far: {count:,}", end='\r')
    except KeyboardInterrupt:
        pass

    count = b["total_samples"][0].value
    print(f"\n\nTotal samples captured: {count:,}")

if __name__ == "__main__":
    main()

