# sim/ — the Cyclesim leg (AGENT.md 1d)

`doom.blob` on the cycle-accurate HardCaml model of the machine: the vendored
[oberon-risc-hardcaml](https://github.com/zxygentoo/oberon-risc-hardcaml)
design, closed with the behavioural PSRAM double widened to the full 16 MiB
(`Cellram_model ~addr_bits:23` — the first full-SoC exercise of 2a's 24-bit
decode), driven by `doom_sim.ml`.

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
| repo root | `default` (stock 5.3) | doomcc, the jig, the emulator, doomrun |
| `sim/` | `5.2.0+ox` | the hardcaml design + `doom_sim` |

The code itself is stock OCaml on both sides; only the dependency universes
are incompatible.

The two worlds meet as **files**, the same seam discipline as everywhere else
in this project: `doom.blob`, `doom1.wad`, `doomboot.rom` (the 26-word boot
stub, `bin/doomboot.ml`) go in; `.fbw` framebuffer dumps (the golden-oracle
format) and cycle counts come out.

## Layout

- `vendor/oberon-risc-hardcaml` — the design, a pristine submodule
  (`data_only` to dune; its own nested emulator submodule stays
  uninitialized). Pin bumps only, like the main workspace's emulator vendor.
- `risc5/`, `nexys4/` — wrapper libs that `copy_files`-compile the submodule's
  `lib/` and `boards/nexys-4/` into this project (the same pattern both repos
  use to vendor the emulator).
- `doom_sim.ml` — the harness: pokes blob + WAD + SHARED page into the PSRAM
  model's byte lanes before releasing reset, boots the doomboot ROM, polls the
  SHARED markers (`+8` init/done, `+16` heartbeat, `+12` exit status), reports
  cycles-per-tick (simulated time is real 60 MHz time — the ms counter ticks
  every 60 000 cycles), and dumps the framebuffer.

## Build & run

```
opam exec --switch=5.2.0+ox -- dune build --root sim

D=$(pwd)  # repo root; dune exec runs from the build dir, use absolute paths
opam exec --switch=5.2.0+ox -- dune exec --root $D/sim ./doom_sim.exe -- \
  $D/doom.blob $D/doom1.wad $D/doomboot.rom \
  -args "-timedemo demo1" -ticks 100 -fbw $D/sim_g00100.fbw
```

`dune runtest` from the repo root never enters this directory; the vendored
design's own inline tests run upstream, not here.

## Gametic convention

Under `-timedemo` (singletics) the heartbeat counts Ticks and gametic =
heartbeat + 1: `-ticks N` parks the machine with gametic N+1 on the screen.
To compare against `golden_gNNNNN.fbw`, run `-ticks N-1` (or generate the
host frame at N+1). Verified 2026-07-09: `-ticks 100` ≡ host gametic 101,
bit-identical.
