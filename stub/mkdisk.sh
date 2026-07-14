#!/usr/bin/env bash
# mkdisk.sh — assemble the bootable DOOM disk image (2c's delivery):
#   stock PO2013 source (extracted from the pinned Oberon-2020-08-18.dsk)
#   + oberon-agent's AgentTool/AgentProtocol + its Oberon.Mod boot-autoload patch
#     (the serial agent channel — drives headless verification, harmless in play)
#   + stub/DOOM.Mod (compiled in-image by the norebo ORP, fully orthodox)
#   + doom.blob, doom1.wad.0/.1 packed verbatim (.packonly)
#   + a DOOM section appended to System.Tool
#
# Host tools come from the vendored OCaml emulator (oberon-risc-hardcaml's own
# nested submodule — one pin, owned by the host repo; dune-built on demand); the
# result boots on the same emulator (16 MiB himem machine):
#   dune exec --root vendor/oberon-risc-hardcaml/vendor/oberon-risc-emu-ocaml \
#     bin/risc.exe -- DOOM.dsk
#
# Real hardware (Nexys 4, the 2a bitstream): the .dsk is a filesystem-only image
# (first word 0x9B1EA38D); BootLoad reads the FS from SD block 0x80000 (BootLoad.Mod
# FSoffset), image byte 0 = block 0x80002 (the emulator's disk.ml applies the same
# rebase in software). Raw device, no partitioning; SW0 off (on = serial boot):
#   sudo dd if=DOOM.dsk of=/dev/sdX bs=512 seek=524290 conv=fsync status=progress
#
# Usage: stub/mkdisk.sh [output.dsk]   (env: EMU=, OA= to relocate the tool repos)
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
EMU=${EMU:-$REPO/vendor/oberon-risc-hardcaml/vendor/oberon-risc-emu-ocaml}
OA=${OA:-$REPO/vendor/oberon-agent}
BIN=$EMU/_build/default/tools/bin
OUT=${1:-$REPO/DOOM.dsk}

for t in extract_source.exe build_po_image.exe ob2txt.exe txt2ob.exe; do
  [ -x "$BIN/$t" ] || { echo "building host tools in $EMU"; \
    opam exec --switch default -- dune build --root "$EMU" \
      tools/bin/ob2txt.exe tools/bin/txt2ob.exe \
      tools/bin/extract_source.exe tools/bin/build_po_image.exe; break; }
done

for f in "$REPO/doom.blob" "$REPO/doom1.wad.0" "$REPO/doom1.wad.1"; do
  [ -f "$f" ] || { echo "missing $f (build with doomcc / wadsplit first)" >&2; exit 1; }
done

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# 1. stock PO2013 source tree
"$BIN/extract_source.exe" "$EMU/DiskImage/Oberon-2020-08-18.dsk" "$T/src"

# 2. the agent channel: autoload patch + the two modules (LF text -> Oberon CR)
"$BIN/ob2txt.exe" "$T/src/Oberon.Mod" >/dev/null
patch --silent "$T/src/Oberon.Mod.txt" <"$OA/Mod/ProjectOberon/Oberon.Mod.patch"
"$BIN/txt2ob.exe" "$T/src/Oberon.Mod.txt" >/dev/null
rm "$T/src/Oberon.Mod.txt"

# 2b. the raw-scancode tap (seam v2 input slice): Input.SetSink diverts the
#     untranslated make/break stream to a registered client (DOOM.Window's
#     point-to-play capture); NIL = stock behaviour, byte-identical
"$BIN/ob2txt.exe" "$T/src/Input.Mod" >/dev/null
patch --silent "$T/src/Input.Mod.txt" <"$REPO/stub/Input.Mod.patch"
"$BIN/txt2ob.exe" "$T/src/Input.Mod.txt" >/dev/null
rm "$T/src/Input.Mod.txt"
for f in "$OA/Mod/Common/AgentProtocol.Mod" "$OA/Mod/ProjectOberon/AgentTool.Mod"; do
  cp "$f" "$T/src/$(basename "$f").txt"
  "$BIN/txt2ob.exe" "$T/src/$(basename "$f").txt" >/dev/null
  rm "$T/src/$(basename "$f").txt"
done

# 3. the stub + the display mode's Oberon face + its demo client (compiled in
#    dependency order like any module — Halftone before its importer Mandel)
for m in DOOM.Mod Halftone.Mod Mandel.Mod; do
  cp "$REPO/stub/$m" "$T/src/$m.txt"
  "$BIN/txt2ob.exe" "$T/src/$m.txt" >/dev/null
  rm "$T/src/$m.txt"
done

# 4. blob + WAD chunks, packed verbatim
cp "$REPO/doom.blob" "$REPO/doom1.wad.0" "$REPO/doom1.wad.1" "$T/src/"
printf 'doom.blob\ndoom1.wad.0\ndoom1.wad.1\n' >>"$T/src/.packonly"

# 5. a DOOM section in System.Tool (middle-click targets)
"$BIN/ob2txt.exe" "$T/src/System.Tool" >/dev/null
printf '\nDOOM.Run\nDOOM.Run -timedemo demo1\nDOOM.RunHW\nDOOM.RunHW -timedemo demo1\nMandel.Open\nDOOM.Window\nDOOM.Window -timedemo demo1\n' >>"$T/src/System.Tool.txt"
"$BIN/txt2ob.exe" "$T/src/System.Tool.txt" >/dev/null
rm "$T/src/System.Tool.txt"

# 6. compile + assemble
"$BIN/build_po_image.exe" "$T/src" "$OUT"
echo "built $OUT"
