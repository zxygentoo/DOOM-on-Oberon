#!/usr/bin/env bash
# The port's source pipeline: preprocess exactly the TUs the port compiles —
# the vendor Makefile's SRC_DOOM list minus the platform TU (doomgeneric_xlib.c,
# which our own DG hooks replace) — into _out/i/*.i, doomcc's input.
# Host gcc/glibc headers on purpose: the .i files carry the glibc prototypes
# the mini-libc's typedefs are written to match (Mergecil matches types by name).
set -euo pipefail
cd "$(dirname "$0")/.."
SRCDIR=vendor/doomgeneric/doomgeneric
# The port's C patches go in first (patch_doomsrc.sh, their one writer —
# idempotent, so a read-only no-op when the Makefile has already run it).
./script/patch_doomsrc.sh
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
  # -DCMAP256: pixel_t is a palette index, DG_ScreenBuffer the 8-bit index
  # buffer, and i_video exports colors[256]/palette_changed for the platform
  # layer's dither LUT. Without it the tree builds the truecolor path
  # (cmap_to_fb RGB conversion) the port never uses.
  # -DDOOMGENERIC_RESX/RESY=320x200: fb_scaling = xres/320 = 1, so
  # DG_ScreenBuffer is the raw 320x200 index buffer (patch 0003 makes it
  # I_VideoBuffer itself) and the scale-up to the panel happens inside the
  # dither blit (libc/dither.c), not in an enlarged intermediate.
  gcc -E -std=gnu99 -DCMAP256 -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200 \
    -I"$SRCDIR" "$SRCDIR/$c" > "_out/i/${c%.c}.i"
  n=$((n + 1))
done
echo "preprocessed $n TUs into _out/i/"
