#!/usr/bin/env bash
# Fetch the shareware DOOM1.WAD v1.9 (freely redistributable) to the repo
# root — the IWAD both the host reference build and the port run (Init pins
# the name "doom1.wad", port.4), and 1d's chunk-splitter input.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -f doom1.wad ]; then
  echo "doom1.wad already present"
  exit 0
fi
url=https://distro.ibiblio.org/slitaz/sources/packages/d/doom1.wad
curl -fL "$url" -o doom1.wad.tmp
md5=$(md5sum doom1.wad.tmp | cut -d' ' -f1)
if [ "$md5" != f0cefca49926d00903cf57551d901abe ]; then
  echo "md5 mismatch: got $md5, want f0cefca49926d00903cf57551d901abe (shareware 1.9)" >&2
  exit 1
fi
mv doom1.wad.tmp doom1.wad
echo "doom1.wad fetched (shareware 1.9, $(stat -c%s doom1.wad) bytes)"
