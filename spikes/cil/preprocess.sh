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
  gcc -E -std=gnu99 -I"$SRCDIR" "$SRCDIR/$c" > "out/i/${c%.c}.i"
  n=$((n + 1))
done
echo "preprocessed $n TUs into out/i/"
