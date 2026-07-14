#!/usr/bin/env bash
# The port's source pipeline: preprocess exactly the TUs the port compiles —
# the vendor Makefile's SRC_DOOM list minus the platform TU (doomgeneric_xlib.c,
# which our own DG hooks replace) — into _out/i/*.i, doomcc's input.
# Host gcc/glibc headers on purpose: the .i files carry the glibc protos the
# mini-libc's typedefs are written to match (nominal Mergecil, AGENT.md 1c.1).
set -euo pipefail
cd "$(dirname "$0")/.."
SRCDIR=vendor/doomgeneric/doomgeneric
# Local source patches (patch/c/*.patch — the C half; patch/oberon/ patches the
# stock PO2013 sources at mkdisk time): the vendor tree is a pinned submodule
# (ignore = dirty — the applied patches keep it modified by design), so our few
# source changes live as reviewed patch files applied idempotently here — a
# fresh checkout and an already-patched tree both converge. 0001 integer-fps
# timedemo (ABI §4 float ban) · 0002 default gamma 2 · 0003/0004 the
# videobuffer alias/fixed-placement pair (fps lever #1, Halftone seam).
for p in patch/c/*.patch; do
  git -C vendor/doomgeneric apply --reverse --check "$PWD/$p" 2>/dev/null \
    || git -C vendor/doomgeneric apply "$PWD/$p"
done
mkdir -p _out/i
rm -f _out/i/*.i
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
    -I"$SRCDIR" "$SRCDIR/$c" > "_out/i/${c%.c}.i"
  n=$((n + 1))
done
echo "preprocessed $n TUs into _out/i/"
