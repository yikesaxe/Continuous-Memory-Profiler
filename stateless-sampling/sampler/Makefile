CC = gcc
CFLAGS = -Wall -Wextra -O2 -fPIC -g
LDFLAGS = -shared -ldl -lpthread -lm

TARGETS = libsampler.so libsampler_timed.so

all: $(TARGETS)

libsampler.so: sampler.c sampler.h
	$(CC) $(CFLAGS) -o $@ sampler.c $(LDFLAGS)

libsampler_timed.so: sampler_timed.c sampler.h
	$(CC) $(CFLAGS) -o $@ sampler_timed.c $(LDFLAGS)

clean:
	rm -f $(TARGETS)

