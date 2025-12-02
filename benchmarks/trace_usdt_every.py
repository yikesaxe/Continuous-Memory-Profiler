#!/usr/bin/env python3
"""
eBPF USDT tracer for Test Case 3a
Traces EVERY allocation via USDT probes
"""

from bcc import BPF, USDT
import argparse
import sys

bpf_text = """
#include <uapi/linux/ptrace.h>

BPF_ARRAY(event_count, u64, 1);

int trace_malloc_every(struct pt_regs *ctx) {
    int zero = 0;
    u64 *count = event_count.lookup(&zero);
    if (count) {
        (*count)++;
    }
    return 0;
}
"""

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-p", "--pid", type=int, required=True)
    args = parser.parse_args()

    print(f"Attaching USDT probes to PID {args.pid}...")
    
    usdt = USDT(pid=args.pid)
    usdt.enable_probe(probe="malloc_every", fn_name="trace_malloc_every")
    
    b = BPF(text=bpf_text, usdt_contexts=[usdt])
    
    print("✅ USDT probes attached")
    print("Tracing every allocation... Press Ctrl-C to stop\n")
    
    try:
        while True:
            pass
    except KeyboardInterrupt:
        count = b["event_count"][0].value
        print(f"\n\nTotal allocations traced: {count:,}")

if __name__ == "__main__":
    main()