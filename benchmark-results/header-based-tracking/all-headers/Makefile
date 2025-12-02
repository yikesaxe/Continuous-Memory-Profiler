CC = gcc
CFLAGS = -O2 -Wall -fPIC -shared
LDFLAGS = -ldl -lm -lpthread

TARGET = libsampler_all_headers.so
SRCS = sampler_all_headers.c

all: $(TARGET)

$(TARGET): $(SRCS) sampler_all_headers.h
	$(CC) $(CFLAGS) $(SRCS) -o $(TARGET) $(LDFLAGS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
