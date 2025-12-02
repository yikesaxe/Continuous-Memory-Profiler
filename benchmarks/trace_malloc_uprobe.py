#!/usr/bin/env python3
"""
eBPF UProbe tracer for Test Case 2
Attaches to EVERY malloc call and collects stack traces
This demonstrates the HIGH OVERHEAD of probing every allocation
"""

from bcc import BPF
import argparse
import signal
import sys

# eBPF program - attaches to malloc and collects minimal data
bpf_text = """
#include <uapi/linux/ptrace.h>

struct alloc_info_t {
    u64 timestamp_ns;
    u32 pid;
    u32 tid;
    u64 size;
    int stack_id;
};

BPF_PERF_OUTPUT(events);
BPF_STACK_TRACE(stack_traces, 10240);

// Counter for total events
BPF_ARRAY(event_count, u64, 1);

int uprobe_malloc(struct pt_regs *ctx, size_t size) {
    // Increment counter
    int zero = 0;
    u64 *count = event_count.lookup(&zero);
    if (count) {
        (*count)++;
    }
    
    // Collect allocation info
    struct alloc_info_t info = {};
    info.timestamp_ns = bpf_ktime_get_ns();
    info.pid = bpf_get_current_pid_tgid() >> 32;
    info.tid = bpf_get_current_pid_tgid();
    info.size = size;
    
    // Collect stack trace (expensive!)
    info.stack_id = stack_traces.get_stackid(ctx, BPF_F_USER_STACK);
    
    // Submit event to userspace (expensive!)
    events.perf_submit(ctx, &info, sizeof(info));
    
    return 0;
}
"""

def main():
    parser = argparse.ArgumentParser(description="UProbe tracer for malloc (HIGH OVERHEAD)")
    parser.add_argument("-p", "--pid", type=int, required=True, help="Process ID to trace")
    args = parser.parse_args()

    print(f"╔════════════════════════════════════════════════════╗")
    print(f"║  eBPF UProbe Tracer - Attaching to malloc()       ║")
    print(f"╠════════════════════════════════════════════════════╣")
    print(f"║  PID: {args.pid:<44} ║")
    print(f"║  This probes EVERY malloc call (high overhead!)    ║")
    print(f"╚════════════════════════════════════════════════════╝")
    print()

    # Load eBPF program
    print("Loading eBPF program...")
    b = BPF(text=bpf_text)
    
    # Attach UProbe to malloc in libc
    print(f"Attaching UProbe to malloc() in PID {args.pid}...")
    b.attach_uprobe(name="c", sym="malloc", fn_name="uprobe_malloc", pid=args.pid)
    
    print()
    print("✅ UProbe attached successfully!")
    print("⚠️  WARNING: This will add ~2-5μs overhead per malloc")
    print()
    print("Switch to the benchmark terminal and press Enter to start...")
    print("Press Ctrl-C here to stop tracing\n")

    event_count = 0
    last_report = 0

    def print_event(cpu, data, size):
        nonlocal event_count, last_report
        event_count += 1
        
        # Report every 100k events
        if event_count - last_report >= 100000:
            print(f"📊 Events captured: {event_count:,}")
            last_report = event_count

    # Process events
    b["events"].open_perf_buffer(print_event, page_cnt=256)
    
    def signal_handler(sig, frame):
        print(f"\n\n╔════════════════════════════════════════════════════╗")
        print(f"║  Tracing Complete                                  ║")
        print(f"╠════════════════════════════════════════════════════╣")
        print(f"║  Total events captured: {event_count:>26,}  ║")
        print(f"╚════════════════════════════════════════════════════╝")
        sys.exit(0)
    
    signal.signal(signal.SIGINT, signal_handler)

    while True:
        try:
            b.perf_buffer_poll(timeout=100)
        except KeyboardInterrupt:
            break

    print(f"\n\nTotal events captured: {event_count:,}")

if __name__ == "__main__":
    main()