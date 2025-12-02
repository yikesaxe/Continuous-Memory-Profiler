#!/usr/bin/env python3
"""
eBPF USDT tracer for Test Case 3b  
Traces only SAMPLED allocations
"""

from bcc import BPF, USDT
import argparse
import sys

bpf_text = """
#include <uapi/linux/ptrace.h>

BPF_ARRAY(sample_count, u64, 1);

int trace_sample_alloc(struct pt_regs *ctx) {
    int zero = 0;
    u64 *count = sample_count.lookup(&zero);
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

    print(f"Attaching USDT sampling probes to PID {args.pid}...")
    
    usdt = USDT(pid=args.pid)
    usdt.enable_probe(probe="sample_alloc", fn_name="trace_sample_alloc")
    
    b = BPF(text=bpf_text, usdt_contexts=[usdt])
    
    print("✅ USDT sampling probes attached")
    print("Tracing only SAMPLED allocations... Press Ctrl-C to stop\n")
    
    try:
        while True:
            pass
    except KeyboardInterrupt:
        count = b["sample_count"][0].value
        print(f"\n\nTotal samples traced: {count:,}")

if __name__ == "__main__":
    main()