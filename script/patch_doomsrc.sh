#!/usr/bin/env bash
# Apply the port's C patches (patch/c/*.patch, in name order) to the vendor
# tree — the one writer of vendor/doomgeneric. The vendor tree is a pinned
# submodule (ignore = dirty: the applied patches keep it modified by design), so
# our source changes live as patch files applied idempotently here: a patch
# already in place is skipped, so a fresh checkout and an already-patched tree
# both converge. (patch/oberon/ patches the stock PO2013 sources, in mkdsk.sh.)
#
# Every consumer of the vendor sources runs after it: the Makefile's
# _out/.patched stamp orders the .i tree and both host oracles (ref, golden),
# and ppx_doomsrc.sh calls it too, so a standalone preprocess converges.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f vendor/doomgeneric/doomgeneric/Makefile ] || {
  echo "vendor/doomgeneric is empty: git submodule update --init --recursive" >&2
  exit 1
}
for p in patch/c/*.patch; do
  git -C vendor/doomgeneric apply --reverse --check "$PWD/$p" 2>/dev/null \
    || git -C vendor/doomgeneric apply "$PWD/$p"
done
