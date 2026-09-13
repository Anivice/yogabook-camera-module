CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Wpedantic
CPPFLAGS ?=
LDFLAGS ?=

.PHONY: all clean wrapper

all: atomisp-yu12-repack wrapper

atomisp-yu12-repack: atomisp-yu12-repack.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -std=gnu11 $(LDFLAGS) -o $@ $<

wrapper:
	chmod +x ffplay-yogabook.sh

clean:
	rm -f atomisp-yu12-repack
