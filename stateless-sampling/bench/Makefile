CC = gcc
CFLAGS = -Wall -Wextra -O2 -g

TARGET = bench_alloc_patterns
SRC = bench_alloc_patterns.c

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $(SRC)

clean:
	rm -f $(TARGET)

