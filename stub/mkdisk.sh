#!/usr/bin/env bash
# mkdisk.sh — assemble the bootable DOOM disk image (2c's delivery):
#   stock PO2013 source (extracted from the pinned Oberon-2020-08-18.dsk)
#   + oberon-agent's AgentTool/AgentProtocol + its Oberon.Mod boot-autoload patch
#     (the serial agent channel — drives headless verification, harmless in play)
#   + stub/DOOM.Mod (compiled in-image by the norebo ORP, fully orthodox)
#   + doom.blob, doom1.wad.0/.1 packed verbatim (.packonly)
#   + a DOOM section appended to System.Tool
#
# Host tools come from the vendored oberon-risc-emu-rs (cargo-built on demand); the
# result boots on the vendored OCaml emulator (16 MiB himem machine):
#   dune exec --root vendor/oberon-risc-emu-ocaml bin/risc.exe -- DOOM.dsk
#
# Usage: stub/mkdisk.sh [output.dsk]   (env: RS=, OA= to relocate the tool repos)
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
RS=${RS:-$REPO/vendor/oberon-risc-emu-rs}
OA=${OA:-$REPO/vendor/oberon-agent}
BIN=$RS/target/release
OUT=${1:-$REPO/DOOM.dsk}

for t in extract-source build-po-image ob2txt txt2ob; do
  [ -x "$BIN/$t" ] || { echo "building host tools in $RS"; \
    cargo build --release --manifest-path "$RS/Cargo.toml" --workspace --bins; break; }
done

for f in "$REPO/doom.blob" "$REPO/doom1.wad.0" "$REPO/doom1.wad.1"; do
  [ -f "$f" ] || { echo "missing $f (build with doomcc / wadsplit first)" >&2; exit 1; }
done

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# 1. stock PO2013 source tree
"$BIN/extract-source" "$RS/DiskImage/Oberon-2020-08-18.dsk" "$T/src"

# 2. the agent channel: autoload patch + the two modules (LF text -> Oberon CR)
"$BIN/ob2txt" "$T/src/Oberon.Mod" >/dev/null
patch --silent "$T/src/Oberon.Mod.txt" <"$OA/Mod/ProjectOberon/Oberon.Mod.patch"
"$BIN/txt2ob" "$T/src/Oberon.Mod.txt" >/dev/null
rm "$T/src/Oberon.Mod.txt"
for f in "$OA/Mod/Common/AgentProtocol.Mod" "$OA/Mod/ProjectOberon/AgentTool.Mod"; do
  cp "$f" "$T/src/$(basename "$f").txt"
  "$BIN/txt2ob" "$T/src/$(basename "$f").txt" >/dev/null
  rm "$T/src/$(basename "$f").txt"
done

# 3. the stub (compiled in dependency order like any module)
cp "$REPO/stub/DOOM.Mod" "$T/src/DOOM.Mod.txt"
"$BIN/txt2ob" "$T/src/DOOM.Mod.txt" >/dev/null
rm "$T/src/DOOM.Mod.txt"

# 4. blob + WAD chunks, packed verbatim
cp "$REPO/doom.blob" "$REPO/doom1.wad.0" "$REPO/doom1.wad.1" "$T/src/"
printf 'doom.blob\ndoom1.wad.0\ndoom1.wad.1\n' >>"$T/src/.packonly"

# 5. a DOOM section in System.Tool (middle-click targets)
"$BIN/ob2txt" "$T/src/System.Tool" >/dev/null
printf '\nDOOM.Run\nDOOM.Run -timedemo demo1\n' >>"$T/src/System.Tool.txt"
"$BIN/txt2ob" "$T/src/System.Tool.txt" >/dev/null
rm "$T/src/System.Tool.txt"

# 6. compile + assemble
"$BIN/build-po-image" "$T/src" "$OUT"
echo "built $OUT"
