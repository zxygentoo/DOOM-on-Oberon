# 1c host reference build (AGENT.md §7/§9): plain gcc on the original
# doomgeneric sources — CIL never touches this path, so a CIL front-end bug
# can't corrupt both sides of the differential.
#
# The TU list is exactly what the target path compiles — read from the
# vendor default Makefile's SRC_DOOM, the same way preprocess.sh reads it
# (one source of truth) — with the platform TU swapped: doomgeneric_xlib.o
# -> doomgeneric_sdl.o. Stock truecolor video (no -DCMAP256): the video mode
# is the platform layer's business and this platform is SDL; game logic is
# identical either way. No -DFEATURE_SOUND: audio is cut (§2), and the
# reference build keeps the port's feature surface. -std=gnu99 is the
# project dialect pin (gcc 15 defaults to C23).
#
# Prereqs (fresh clone): spikes/cil/fetch-doomgeneric.sh, then
# spikes/cil/preprocess.sh — which applies patches/0001 (integer-fps
# timedemo) to the vendor tree; the host build must share that patch or
# the two sides diverge on G_CheckDemoStatus.

SRCDIR := ../spikes/cil/vendor/doomgeneric/doomgeneric

CC := gcc
CFLAGS := -std=gnu99 -O2 -Wall $(shell sdl2-config --cflags)
LIBS := -lm $(shell sdl2-config --libs)

OBJDIR := build
OUTPUT := doomgeneric

SRC_DOOM := $(shell sed -n 's/^SRC_DOOM = //p' $(SRCDIR)/Makefile)
SRC := $(patsubst doomgeneric_xlib.o,doomgeneric_sdl.o,$(SRC_DOOM))
OBJS := $(addprefix $(OBJDIR)/,$(SRC))

all: $(OUTPUT)

$(OUTPUT): $(OBJS)
	$(CC) $(OBJS) -o $@ $(LIBS)

$(OBJDIR)/%.o: $(SRCDIR)/%.c | $(OBJDIR)
	$(CC) $(CFLAGS) -I$(SRCDIR) -c $< -o $@

$(OBJDIR):
	mkdir -p $(OBJDIR)

clean:
	rm -rf $(OBJDIR) $(OUTPUT)

.PHONY: all clean
