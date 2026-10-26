# DOOM on Oberon — working rules

DOOM, compiled by an all-OCaml C toolchain to a flat RISC5 blob that an Oberon command
loads and runs, on the [oberon-risc-hardcaml](https://github.com/zxygentoo/oberon-risc-hardcaml)
machine: its emulator, its cycle-accurate model and a Nexys 4. This file holds what you
must know before changing anything; the rest is reference:

| Read | For |
|---|---|
| `README.md` | what it is; how to build, check and run it |
| `ABI.md` | the frozen contract: registers, calls, types, the blob format, the memory map, Halftone |
| `docs/design.md` | the design: decisions, toolchain, runtime, input, verification |
| `sim/README.md` | the cycle-accurate leg and its separate dune root |
| `THIRD_PARTY.md` | what comes from elsewhere, and its terms |
| `build-log.md` | how it was built: every slice, measurement and dead end |

## How we work

This began as a learning project — compiler backends, systems programming, bringing a
large C program onto a bare machine — and the working agreement stays:

- **Explain before building.** For a change, walk the problem first (the C construct,
  the ABI rule, the RISC5 encoding, the DOOM-side gotcha), then how it maps onto the
  code, then write it. Teach the why.
- **Small, reviewable increments**, one at a time. Don't run ahead into adjacent work;
  the human sets the pace.
- **Pair the code with its spec** — `ABI.md`, `risc5_isa.mli`, the CIL AST, the
  doomgeneric source — and say where a choice departs from the obvious transliteration.
- **Nothing is done until its gate is green** (below).
- **The human reviews every diff before it is committed.**

## Rules

1. **Refuse, never miscompile.** A construct outside the ABI's types is refused by
   `lib/check.ml` with a reason; a backend bug raises `Check.Internal` and fails the build.
   A function the gate refuses links as a self-loop trap, so reaching it hangs where
   `run_blob` can name it.
2. **Every compiler or hand-code change passes the jig**, and a new construct or fix
   arrives with a sample that fails before and passes after.
3. **Artifacts have invariants.** A change that should not move `doom.blob` leaves it
   byte-identical — compare the md5. One that does runs `make check`. A change to the disk
   image runs the on-system checks (`run_dsk`); a change to the hardware path ends with a
   run on the board.
4. **`ABI.md` is frozen at v1.** Changing a field, offset or rule means `version = 2`;
   additions to reserved fields are allowed (its §10). `lib/abi_constants.ml` and
   `DOOM.Mod` restate its constants.
5. **Measure, don't guess.** Profiles before and after (`run_blob -profile` counts
   instructions, `run_sim -profile` cycles), over the same work.
6. **The blob never touches storage,** and knows nothing of Oberon; the stub owns every
   file and every piece of Oberon citizenship.
7. **The vendor trees stay pristine**, except doomgeneric, which
   `script/patch_doomsrc.sh` alone patches from `patch/c/`. To change a patch, reset the
   submodule (`git -C vendor/doomgeneric checkout -- .`) and let `make` re-apply it.

## Layout

- `lib/`: `doomcc_core`, the compiler — `frontend` (CIL), `globals` (data layout),
  `fundec` (codegen), `check` (the refusal gate), `linker`, `blob`, `crt0`, `wad` (the
  chunk split), and the hand-written `runtime` and `drawers` over the `asm` eDSL. Also `abi_constants` (the §8
  page as code) and `run_harness` (the run_* tools' shared plumbing).
- `bin/`: `doomcc` (the driver), `run_blob` (the blob on the emulator), `run_dsk` (the
  disk image on the emulator, scripted), `split_wad`, `emit_rom` (the Cyclesim boot ROM),
  `emit_bn64` (the blue-noise table), `doom_golden.c` (the host side of the pixel oracle).
- `libc/`: the mini-libc and the platform layer (`doom_oberon.c`), compiled by doomcc.
- `patch/c/`: changes to doomgeneric. `patch/oberon/`: `DOOM.Mod` (the stub) and the
  `Input.Mod` raw-scancode tap.
- `script/`: preprocessing, patching, the disk image, the oracle check, prerequisites.
- `test/`: the jig and its runner, the blob-envelope and WAD-split tests.
- `sim/`: the Cyclesim leg — its own dune root, on another switch.
- `vendor/`: `doomgeneric` and `oberon-risc-hardcaml` (submodules; the emulator is
  nested inside the latter); `vendor/emu` builds the emulator's core as library `emu`.
- `_out/`: every generated or fetched artifact (git-ignored); `make clean` removes it.

## Gates

| Gate | Checks | Time |
|---|---|---|
| `make test` (`dune runtest`) | the jig — about 250 samples against gcc, plus self-checks and gate rejects — and the blob, runner and WAD-split tests | 5 min |
| `make check` | golden frames bit-identical at four gametics, both runs timed 5026 | 7 min |
| `bin/run_dsk.exe` timelines | the disk image on the booted OS: play and quit, `-win`, the timedemo | seconds; 15 min for the timedemo |
| `make sim`, then `run_sim` | the shipped SoC under Cyclesim: cycles per tick, the frame against the golden | about an hour |
| the board | the timedemo, 5026 | — |

## Conventions

- **Two switches.** The root builds on the stock `default` switch (goblint-cil); `sim/`
  on `5.2.0+ox` (the hardcaml preview). Every `make` target names its switch (`SWITCH=`,
  `OXSWITCH=` to override). `make prereqs` checks the rest.
- **Format.** `dune fmt` on the `default` switch before each commit; `dune build @fmt`
  must be clean. `sim/` is a separate root the root's formatting does not reach.
- **Naming.** Modules are named for the artifact (`Fundec`, `Globals`); tools are
  verb_noun (`run_blob`, `emit_rom`, `split_wad`); C files are `doom_*`; it is a dsk, not
  a disk; patch files take verb-first slugs.
- **C in `libc/`** is preprocessor-free (CIL parses it directly) and spells types as the
  host-preprocessed `.i` files do (`size_t` is `unsigned long`): `Mergecil` matches types
  by name.
- **Comments** say why: the hazard, the invariant, the non-obvious choice. No history,
  slice names or measurement stories (those belong in `build-log.md`); interface docs and
  tool usage headers stay clean; hand-written assembly keeps its register plans.
- **Git.** `main` holds releases, `develop` integrates, work happens on `feat/<name>`.
  Commit messages end with the agent's `Co-Authored-By:` trailer.

## Traps

- `m_fixed.i` must never be compiled: host preprocessing spells `int64_t` as x86-64
  `long`, which ILP32 makes 32 bits. doomcc skips it.
- CIL leaves statement ids at -1 until a CFG pass; doomcc numbers them per function, or
  every label collides.
- A variadic callee reads its arguments from the caller's home area; hand code calling
  one stores R0–R3 there. R12 is the callee-saved frame pointer; hand code that uses it
  saves it. The Runner checks R6–R12 after every sample.
- The Halftone raster must never see a frame being drawn: the blob copies finished
  frames into the window.
- The emulator has no Halftone: there `DOOM.Run` takes the software dither and `-win`
  refuses.
- `run_dsk` writes the disk in place — pass a copy. Loading plus `D_DoomMain` take about
  12 simulated seconds, and the stub drains keys typed before the first tick: send scripted
  keys 20 s or more into a timeline.
- `dune exec` runs from the build directory: give `run_sim` absolute paths. `-ticks N`
  parks with gametic N+1 on the screen; Init alone is ~190 M cycles.
- The emulator's serial agent shares the UART with DOOM's console: a call's own reply
  never survives DOOM's output, so read the result off the wire.

## Settled — bring new evidence before reopening

- Register allocation beyond the naive scheme, and general inlining (ceiling about 2.5%
  of cycles): parked; the hot loops are hand-written. A loop-promotion pass measured
  −0.6% and was reverted.
- The dither's look — blue noise at σ 1.5, gamma 2, weights (150, 80, 26), out2 — was
  chosen by eye on contact sheets.
- The clock is 64 MHz; a 75 MHz attempt cost the cache more than it gained.
- Fullscreen `DOOM.Run` stays outside the Halftone claim (`ABI.md` §11).
