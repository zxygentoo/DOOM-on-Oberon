#!/usr/bin/env bash
# CIL spike (AGENT.md §9): preprocess exactly the TUs our port would compile —
# the Makefile's SRC_DOOM list minus the platform TU (doomgeneric_xlib.c,
# which our own DG hooks replace). Host gcc/glibc headers are fine for the
# parse/merge gate; the real pipeline will use a 32-bit machdep + mini-libc
# headers.
set -euo pipefail
cd "$(dirname "$0")"
SRCDIR=vendor/doomgeneric/doomgeneric
mkdir -p out/i
rm -f out/i/*.i
srcs=$(sed -n 's/^SRC_DOOM = //p' "$SRCDIR/Makefile")
n=0
for o in $srcs; do
  c="${o%.o}.c"
  case "$c" in doomgeneric_xlib.c) continue ;; esac
  # -std=gnu99: gcc 15 defaults to C23, whose true/false *keywords* leak
  # through doomtype.h's C89 fallback and break CIL's (C11) grammar. The
  # real pipeline is C99-dialect anyway.
  # -DCMAP256: the locked video mode (AGENT.md §2.1/§5) — pixel_t is a
  # palette index, DG_ScreenBuffer the 8-bit index buffer, and i_video
  # exports colors[256]/palette_changed for the platform layer's dither
  # LUTs. Without it the tree builds the truecolor path (cmap_to_fb RGB
  # conversion) our port never uses.
  # -DDOOMGENERIC_RESX/RESY=320x200: fb_scaling = xres/320 = 1, so
  # I_FinishUpdate degenerates to a per-line copy and DG_ScreenBuffer is the
  # raw 320x200 index buffer — the 2x2 doubling happens inside the dither
  # blit (libc/dither.c), not as a byte-doubled 256 KB intermediate.
  gcc -E -std=gnu99 -DCMAP256 -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200 \
    -I"$SRCDIR" "$SRCDIR/$c" > "out/i/${c%.c}.i"
  n=$((n + 1))
done
echo "preprocessed $n TUs into out/i/"
