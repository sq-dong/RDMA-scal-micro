CC      := gcc
CFLAGS  := -O3 -Wall -Wextra -Wno-unused-parameter -I.
LDFLAGS := -libverbs -lpthread

BINS := scale_bench

all: $(BINS)

common.o: common.c common.h
	$(CC) $(CFLAGS) -c -o $@ $<

scale_bench: scale_bench.c common.o
	$(CC) $(CFLAGS) -o $@ $< common.o $(LDFLAGS)

clean:
	rm -f $(BINS) *.o

.PHONY: all clean
