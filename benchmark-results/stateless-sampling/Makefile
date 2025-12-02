CC = gcc
CFLAGS = -O2 -Wall -fPIC -shared
LDFLAGS = -ldl -lm -lpthread

TARGET = libsampler_stateless.so
SRCS = sampler_stateless.c

all: $(TARGET)

$(TARGET): $(SRCS) sampler_stateless.h
	$(CC) $(CFLAGS) $(SRCS) -o $(TARGET) $(LDFLAGS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
