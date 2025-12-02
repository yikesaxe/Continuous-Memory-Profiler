CC = gcc
CFLAGS = -O2 -Wall -fPIC -shared
LDFLAGS = -ldl -lm -lpthread

TARGET = libsampler_sample_headers.so
SRCS = sampler_sample_headers.c

all: $(TARGET)

$(TARGET): $(SRCS) sampler_sample_headers.h
	$(CC) $(CFLAGS) $(SRCS) -o $(TARGET) $(LDFLAGS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
