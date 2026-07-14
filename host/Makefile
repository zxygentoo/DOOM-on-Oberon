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
# Prereqs (fresh clone): git submodule update --init vendor/doomgeneric,
# then ./preprocess.sh — which applies patch/0001 (integer-fps timedemo)
# to the vendor tree; the host build must share that patch or the two
# sides diverge on G_CheckDemoStatus.

SRCDIR := ../vendor/doomgeneric/doomgeneric

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
	rm -rf $(OBJDIR) $(OUTPUT) $(GOBJDIR) golden

# golden — the headless golden-frame generator (1d's visual oracle): the same
# TU list in the port's video mode (CMAP256, 320x200) plus doomgeneric_golden.c
# and THE SHIPPED ../libc/dither.c, built -m32 -funsigned-char — the jig
# oracle's model of the target (ILP32, char unsigned). No SDL, no sound.

GOBJDIR := build32
GCFLAGS := -std=gnu99 -O2 -Wall -m32 -funsigned-char \
  -DCMAP256 -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200
GSRC := $(patsubst doomgeneric_xlib.o,doomgeneric_golden.o,$(SRC_DOOM)) dither.o
GOBJS := $(addprefix $(GOBJDIR)/,$(GSRC))

golden: $(GOBJS)
	$(CC) -m32 $(GOBJS) -o $@ -lm

$(GOBJDIR)/%.o: $(SRCDIR)/%.c | $(GOBJDIR)
	$(CC) $(GCFLAGS) -I$(SRCDIR) -c $< -o $@

$(GOBJDIR)/doomgeneric_golden.o: doomgeneric_golden.c | $(GOBJDIR)
	$(CC) $(GCFLAGS) -I$(SRCDIR) -c $< -o $@

$(GOBJDIR)/dither.o: ../libc/dither.c | $(GOBJDIR)
	$(CC) $(GCFLAGS) -c $< -o $@

$(GOBJDIR):
	mkdir -p $(GOBJDIR)

.PHONY: all clean
