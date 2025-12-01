CC = gcc
CFLAGS = -Wall -Wextra -O2 -fPIC -g
LDFLAGS = -shared -ldl -lpthread -lm

TARGET = libsampler.so
SRC = sampler.c

all: $(TARGET)

$(TARGET): $(SRC) sampler.h
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDFLAGS)

clean:
	rm -f $(TARGET)

