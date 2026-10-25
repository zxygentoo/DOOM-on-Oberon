# sim/ — the Cyclesim leg

`doom.blob` on the cycle-accurate Hardcaml model of the machine: the vendored
[oberon-risc-hardcaml](https://github.com/zxygentoo/oberon-risc-hardcaml)
board SoC, closed with the behavioural PSRAM double widened to the full
16 MiB (`Cellram_model ~addr_bits:23`), driven by `run_sim.ml`.

## Why a separate dune project

This directory is its **own dune root**, deliberately outside the main
workspace (the root `dune` excludes it). The split is forced by opam, not
preference:

- The hardware design builds against **hardcaml v0.18-preview**, which exists
  only in the **OxCaml opam repository** — a sealed package universe whose
  `oxcaml-*` variants (yojson, ppx_deriving, dune-configurator, …) conflict
  with the stock packages that **goblint-cil** (the compiler front-end in the
  main workspace) depends on. The solver rejects goblint-cil on the ox switch
  outright.
- The mirror direction is equally blocked: hardcaml v0.18-preview can't come
  to the stock `default` switch without hand-pinning the entire unreleased
  Jane Street preview stack.

One dune workspace builds under one switch, so the two package universes mean
two roots:

| root | switch | world |
|---|---|---|
| repo root | `default` (stock 5.3) | doomcc, the jig, the emulator, run_blob |
| `sim/` | `5.2.0+ox` | the hardcaml design + `run_sim` |

The code itself is stock OCaml on both sides; only the dependency universes
are incompatible.

The two worlds meet as **files**, the same seam discipline as everywhere else
in this project: `doom.blob`, `doom1.wad`, `doomboot.rom` (the 32-word boot
ROM, `bin/emit_rom.ml`, `make rom`) go in; `.fbw` framebuffer dumps (the
golden-oracle format) and cycle counts come out.

## Layout

- `vendor/oberon-risc-hardcaml` — a symlink to the root's submodule (one
  checkout, two workspace roots), pristine and `data_only` to dune; the main
  workspace's `emu` reads the emulator from its nested submodule. Pin bumps
  happen at the root.
- `risc5/`, `nexys4/` — wrapper libs that `copy_files`-compile the submodule's
  `lib/` and `board/nexys-4/` into this project (the same pattern both repos
  use to vendor the emulator).
- `run_sim.ml` — the harness: pokes blob + WAD + SHARED page into the PSRAM
  model's byte lanes before releasing reset, boots the doomboot ROM, polls the
  SHARED markers (`+8` init/done, `+16` heartbeat, `+12` exit status), reports
  cycles per tick, and dumps the framebuffer. Simulated time is the board's:
  the ms counter ticks every 60 000 cycles — the 60 MHz build every number
  here was measured on; the pinned host now ships 64 MHz.

## Build & run

```
opam exec --switch=5.2.0+ox -- dune build --root sim     # or: make sim

D=$(pwd)  # repo root; dune exec runs from the build dir, use absolute paths
opam exec --switch=5.2.0+ox -- dune exec --root $D/sim ./run_sim.exe -- \
  $D/_out/doom.blob $D/_out/doom1.wad $D/_out/doomboot.rom \
  -args "-timedemo demo1" -ticks 100 -fbw $D/_out/sim_g00100.fbw
```

`dune runtest` from the repo root never enters this directory; the vendored
design's own inline tests run upstream, not here.

## Gametic convention

Under `-timedemo` (singletics) the heartbeat counts Ticks and gametic =
heartbeat + 1: `-ticks N` parks the machine with gametic N+1 on the screen.
To compare against `golden_gNNNNN.fbw`, run `-ticks N-1` (or generate the
host frame at N+1): `-ticks 100` ≡ host gametic 101, bit-identical.

## -hw: the Halftone scanout

`-hw` turns the video DMA and the Halftone scanout on (`video fb_bram
halftone`; fb_bram is proven cycle-identical to the video-off build, so
cycles/tick stay comparable with non-hw runs) and advertises the hardware to
the blob in SHARED +544 (ABI.md §11). The blob then copies each frame into
the Halftone window instead of dithering it. `-fbw` in this mode dumps the
frame the panel shows: after the park, the raster free-runs one full scan
(~1.1 M cycles) and the harness rebuilds the .fbw from `ht_ack`/`ht_word`
plus the SoC's `vidreq`/`vidadr` — same file format, same golden
comparison.
