#!/usr/bin/env bash
# CIL spike (DOOM.md §9): fetch the doomgeneric tree the spike parses.
set -euo pipefail
cd "$(dirname "$0")"
[ -d vendor/doomgeneric ] \
  || git clone --depth 1 https://github.com/ozkl/doomgeneric vendor/doomgeneric
