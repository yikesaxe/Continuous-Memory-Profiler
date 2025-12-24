CC = gcc
CFLAGS = -Wall -Wextra -O2 -g

TARGETS = bench_alloc_patterns bench_sampling_overhead

all: $(TARGETS)

bench_alloc_patterns: bench_alloc_patterns.c
	$(CC) $(CFLAGS) -o $@ $<

bench_sampling_overhead: bench_sampling_overhead.c
	$(CC) $(CFLAGS) -o $@ $< -lm

clean:
	rm -f $(TARGETS)

