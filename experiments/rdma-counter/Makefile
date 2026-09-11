CC      ?= gcc
CFLAGS  := -O2 -g -Wall -Wextra -std=gnu11
LDLIBS  := -libverbs

all: counter_bench

counter_bench: counter_bench.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f counter_bench

.PHONY: all clean
