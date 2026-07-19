# DOOM-on-Oberon — the pipeline as a dependency graph. Every generated or
# fetched artifact lives under _out/ (the root stays source-only); every
# target encodes its opam switch, so the ox-vs-default trap can't bite.
#
#   make blob      the DOOM blob (doomcc over _out/i + libc)
#   make dsk       the bootable DOOM.dsk (script/mkdsk.sh)
#   make ref       the SDL reference build (plain gcc — the 5026 oracle)
#   make golden    the -m32 golden-frame generator binary
#   make goldens   run it: _out/golden/golden_g*.fbw (the pixel oracle)
#   make test      the differential jig (dune runtest, default switch)
#   make fmt       dune fmt (default switch — the pre-commit gate)
#   make sim       the Cyclesim leg (dune --root sim, OxCaml switch)
#
# Independence property (AGENT.md §9): the ref/golden recipes are plain gcc
# on the original vendor sources — no CIL, no doomcc, no dune anywhere in
# them — so a toolchain bug can't corrupt both sides of a differential. The
# golden build shares exactly ONE file with the target path: libc/dither.c,
# the shipped kernel, making every golden comparison a full-scale compiler
# differential. Don't let either recipe grow a dune dependency.

DUNE  := opam exec --switch default -- dune
DUNEX := opam exec --switch=5.2.0+ox -- dune

SRCDIR := vendor/doomgeneric/doomgeneric
LIBC   := libc/mini.c libc/stdio.c libc/fixed.c libc/doom_heap.c \
          libc/doom_oberon.c libc/dither.c

.PHONY: all build blob chunks dsk rom i wad ref golden goldens test fmt sim clean

all: blob dsk

# ---- the OCaml side (dune, default switch) --------------------------------

build:
	$(DUNE) build

test:
	$(DUNE) runtest

fmt:
	$(DUNE) fmt

sim:
	$(DUNEX) build --root sim

# ---- the source pipeline ---------------------------------------------------

# the .i tree: patch the vendor submodule (idempotent) + gcc -E the SRC_DOOM
# TU list; script/ppx_doomsrc.sh owns the logic, this rule owns the ordering
i _out/i/.stamp: script/ppx_doomsrc.sh $(wildcard patch/c/*.patch)
	./script/ppx_doomsrc.sh
	@touch _out/i/.stamp

# the shareware IWAD v1.9 (freely redistributable) — md5-pinned; the name
# "doom1.wad" is baked into the blob's Init (port.4). Mirrors are tried in
# order until one matches the pin (the original slitaz URL died 2026-07):
# the md5, not the host, is the trust anchor.
WAD_URLS := \
  https://raw.githubusercontent.com/Doom-Utils/shareware-collection/master/Doom%201.9/doom1.wad \
  https://raw.githubusercontent.com/Akbar30Bill/DOOM_wads/master/doom1.wad
WAD_MD5 := f0cefca49926d00903cf57551d901abe

wad: _out/doom1.wad
_out/doom1.wad:
	@mkdir -p _out
	@ok=; for url in $(WAD_URLS); do \
	  echo "curl $$url"; \
	  if curl -fL --connect-timeout 20 "$$url" -o $@.tmp \
	     && test "$$(md5sum $@.tmp | cut -d' ' -f1)" = "$(WAD_MD5)"; \
	  then ok=1; break; else echo "  mirror failed or md5 mismatch — trying next"; fi; \
	done; \
	test -n "$$ok" || { echo "no mirror yielded shareware 1.9 (md5 $(WAD_MD5))"; rm -f $@.tmp; exit 1; }
	mv $@.tmp $@

# ---- the port's artifacts ---------------------------------------------------

blob: _out/i/.stamp
	$(DUNE) exec bin/doomcc.exe -- _out/i/*.i $(LIBC) -o _out/doom.blob

chunks _out/doom1.wad.0: _out/doom1.wad
	$(DUNE) exec bin/split_wad.exe -- _out/doom1.wad

rom:
	$(DUNE) exec bin/emit_rom.exe -- -o _out/doomboot.rom

dsk: blob chunks
	./script/mkdsk.sh

# ---- the host oracles (plain gcc — keep dune-free, see header) --------------

CC := gcc
SRC_DOOM = $(shell sed -n 's/^SRC_DOOM = //p' $(SRCDIR)/Makefile)

# the reference build: 64-bit SDL2, stock truecolor, original sources — the
# independent implementation behind the 5026-gametic desync constant
RDIR   := _out/ref
RFLAGS := -std=gnu99 -O2 -Wall $(shell sdl2-config --cflags)
RSRC    = $(patsubst doomgeneric_xlib.o,doomgeneric_sdl.o,$(SRC_DOOM))
ROBJS   = $(addprefix $(RDIR)/,$(RSRC))

ref: $(RDIR)/doomgeneric
$(RDIR)/doomgeneric: $(ROBJS)
	$(CC) $(ROBJS) -o $@ -lm $(shell sdl2-config --libs)

$(RDIR)/%.o: $(SRCDIR)/%.c | $(RDIR)
	$(CC) $(RFLAGS) -I$(SRCDIR) -c $< -o $@

$(RDIR):
	mkdir -p $(RDIR)

# the golden-frame generator: the same TUs in the port's video mode
# (CMAP256, 320x200), -m32 -funsigned-char (the jig oracle's target model),
# headless platform layer bin/doom_golden.c + THE SHIPPED libc/dither.c
GDIR   := _out/golden
GFLAGS := -std=gnu99 -O2 -Wall -m32 -funsigned-char \
          -DCMAP256 -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200
GSRC    = $(patsubst doomgeneric_xlib.o,doom_golden.o,$(SRC_DOOM)) dither.o
GOBJS   = $(addprefix $(GDIR)/,$(GSRC))

golden: $(GDIR)/golden
$(GDIR)/golden: $(GOBJS)
	$(CC) -m32 $(GOBJS) -o $@ -lm

$(GDIR)/%.o: $(SRCDIR)/%.c | $(GDIR)
	$(CC) $(GFLAGS) -I$(SRCDIR) -c $< -o $@

$(GDIR)/doom_golden.o: bin/doom_golden.c | $(GDIR)
	$(CC) $(GFLAGS) -I$(SRCDIR) -c $< -o $@

$(GDIR)/dither.o: libc/dither.c | $(GDIR)
	$(CC) $(GFLAGS) -c $< -o $@

$(GDIR):
	mkdir -p $(GDIR)

# run the generator (cwd = _out/golden: the engine fopens "doom1.wad" in cwd,
# frames land as golden_gNNNNN.fbw next to it); GOLDEN_TICS/KEYS/SCENES/ARGS
# pass through for the lab side doors
goldens: golden _out/doom1.wad
	@ln -sf ../doom1.wad $(GDIR)/doom1.wad
	cd $(GDIR) && ./golden; st=$$?; test $$st -eq 255 -o $$st -eq 0 || exit $$st
	@ls $(GDIR)/golden_g*.fbw

clean:
	rm -rf _out
