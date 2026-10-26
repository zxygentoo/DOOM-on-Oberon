# DOOM on Oberon

> **operating system** *(n.)* — anything that runs DOOM.

By that definition, Project Oberon has qualified at last.

**DOOM, as an Oberon command, on Niklaus Wirth's RISC5 machine** — compiled by a C
toolchain written for it in OCaml, loaded by a small Oberon-07 module, and running on
[the Hardcaml RISC5](https://github.com/zxygentoo/oberon-risc-hardcaml) on a Digilent
Nexys 4, its cycle-accurate model, and
[the emulator](https://github.com/zxygentoo/oberon-risc-emu-ocaml).

![DOOM's title screen, dithered to one bit per pixel across the 1024 × 768 Oberon screen](doom.png)

*The title screen in the emulator: DOOM's 320 × 200 palette frame, dithered onto the
machine's one-bit screen. On the board, the display hardware does the dithering.*

On the board, DOOM runs at **15 frames a second** at 64 MHz, fullscreen or in a viewer
beside the live desktop, and its timedemo ends at exactly the tick count of a reference
PC build.

![The Nexys 4 board beside a monitor showing the Project Oberon desktop with DOOM's title screen in a viewer](https://raw.githubusercontent.com/zxygentoo/oberon-risc-hardcaml/v0.1.0/docs/oberon-on-nexys4.jpg)

*On the board, in a viewer (photo from the hardware repository).*

The goal was to have some fun with the Oberon machine built in
[the hardware project](https://github.com/zxygentoo/oberon-risc-hardcaml), not to build
a C compiler for it — so it compiles exactly as much C as DOOM needs, and many corners
are strategically cut: no `long long`, no floating point at run time, no structs passed
by value, a register allocator that would embarrass a textbook, and a `malloc` that never
frees. XD

## What is in here

| Path | What |
|---|---|
| `lib/`, `bin/doomcc.ml` | the compiler: the CIL front end, the RISC5 backend, the linker, and the hand-written runtime and drawers |
| `libc/` | the mini-libc, the doomgeneric platform layer, the one-bit dither |
| `patch/c/` | the port's changes to doomgeneric |
| `patch/oberon/` | the loader, `DOOM.Mod`, and a raw-scancode tap for Oberon's `Input` module |
| `ABI.md` | the contract between compiler, blob and loader: registers, calls, types, the blob format, the memory map, the Halftone interface |
| `test/` | the differential jig: the compiler against gcc |
| `bin/run_*.ml`, `sim/` | DOOM on the emulator, on the booted OS, and on the cycle-accurate model |

## How it works

There was no C compiler for RISC5, so there is one here, in OCaml.

- **Compiling.** The [CIL](https://github.com/goblint/cil) front end parses
  [doomgeneric](https://github.com/ozkl/doomgeneric)'s 80 C files and a small libc into one
  program; the backend turns it into RISC5 instructions, refusing anything outside the
  ABI rather than miscompiling it. The hottest loops — the dither, `R_DrawSpan`,
  `R_DrawColumn` — are hand-written over the same instruction type, each checked against
  gcc compiling the C it replaces. A linker lays it all out as `doom.blob`.
- **Loading.** `DOOM.Mod`, an ordinary Oberon module, reads the blob and the WAD (in two
  files: Oberon caps a file at about 3 MB) into the memory above Oberon's own megabyte,
  then calls `Init` once, `Tick` every frame and `KeyIn` for each key. DOOM never touches
  storage, and always returns to Oberon.
- **Drawing.** DOOM renders 320 × 200 palette frames. On the board, the Halftone display
  mode dithers them onto the one-bit screen as it scans out; elsewhere the blob dithers
  them itself. The pixels are the same either way.
- **Keys.** DOOM needs key releases, which Oberon's `Input` module discards, so the loader
  reads raw PS/2 scancodes.

## Getting started

You need Linux on x86-64, [opam](https://opam.ocaml.org) with OCaml 5.3 or later, gcc
with 32-bit multilib (the test oracle compiles for the target's data model), and SDL2 for
the emulator's window. The Makefile builds on the opam switch named `default`;
`make SWITCH=...` picks another.

```sh
git clone --recurse-submodules https://github.com/zxygentoo/DOOM-on-Oberon.git
cd DOOM-on-Oberon

opam install --switch default --deps-only .   # goblint-cil, crunch
opam install --switch default tsdl imagelib   # the emulator's window
make prereqs                                  # checks the rest, with install hints

make        # the blob and the bootable disk image, in _out/
make run    # boot a copy in the emulator
```

`make` downloads the shareware `doom1.wad` and checks its md5. In the emulator,
middle-click `DOOM.Run` in the `System.Tool` viewer (Left Alt is the middle button on a
trackpad). The emulator has no Halftone display mode, so DOOM dithers in software there,
and `DOOM.Run -win`, which opens DOOM in a viewer, needs the board.

| Key | In DOOM |
|---|---|
| arrows | move and turn |
| Ctrl | fire |
| Space | use (doors, switches) |
| Shift | run |
| Alt | strafe, with the arrows (`,` `.` strafe too) |
| 1 – 7 | weapons |
| Esc, Enter | the menu |
| Tab | the map |
| F10, then `y` | quit back to Oberon |

In a viewer, the keys go to DOOM while the mouse pointer is over the game.

## Checking it

| Gate | What it checks | Time |
|---|---|---|
| `make test` | the differential jig: about 250 C samples, compiled here and run in the emulator, against gcc; plus self-checks and the refusals | 5 min |
| `make check` | DOOM's demo on the emulator against a host build of the same sources: the framebuffer bit-identical at four points, both runs ending at exactly 5026 game ticks | 7 min |
| `bin/run_dsk.exe` | the disk image on the booted OS, driven by a scripted timeline of keys and clicks | minutes |
| `make sim` + `run_sim` | the blob on the cycle-accurate model of the shipped machine ([`sim/README.md`](sim/README.md)) | an hour |

`make ref` builds DOOM for the PC from the same patched sources, with SDL — the
reference the tick count comes from.

## How fast

| | Clocks per tick | Frames a second |
|---|---|---|
| the board, 64 MHz, through Halftone | — | **15.0** |
| the cycle-accurate model, through Halftone | 3.53 M | 18.2 |
| the cycle-accurate model, software dither | 7.19 M | 8.9 |

Measurement chose where to optimize: profiles found most of each frame in four
functions, and what paid was hand-writing those loops, moving the dither into the display
hardware, and a 16 KiB cache on the board. Better register allocation and general
inlining were priced and parked ([`build-log.md`](build-log.md)).

## On a board

You need a Nexys 4 (the original, with cellular RAM) set up as in
[the hardware repository](https://github.com/zxygentoo/oberon-risc-hardcaml#on-a-board),
running its `v0.1.0` bitstream
([`oberon.bit`](https://github.com/zxygentoo/oberon-risc-hardcaml/releases/tag/v0.1.0)),
and a microSD card. The disk image is the Oberon file system alone, and the board expects
it 0x80002 blocks into the card:

```sh
sudo dd if=_out/DOOM.dsk of=/dev/sdX bs=512 seek=524290 conv=fsync
```

Boot, then middle-click `DOOM.Run` or `DOOM.Run -win`.

## Documents

- [`AGENTS.md`](AGENTS.md) — the working rules: the gates, the invariants, the layout,
  the conventions and traps.
- [`docs/design.md`](docs/design.md) — the design: the decisions, the toolchain, the
  runtime, input, verification.
- [`ABI.md`](ABI.md) — the frozen contract between compiler, blob and loader.
- [`sim/README.md`](sim/README.md) — the cycle-accurate leg.
- [`build-log.md`](build-log.md) — how it was built, slice by slice, with every
  measurement.

## Related repositories

- [`oberon-risc-hardcaml`](https://github.com/zxygentoo/oberon-risc-hardcaml) — the
  machine: the Hardcaml RISC5, its board layer and the Halftone display mode, vendored
  here as a submodule.
- [`oberon-risc-emu-ocaml`](https://github.com/zxygentoo/oberon-risc-emu-ocaml) — the
  emulator and the disk-image tools, nested in the hardware repository; the compiler
  shares its instruction encoding.

## Credits

DOOM is id Software's; doomgeneric is ozkl's, on Chocolate Doom by Simon Howard. Project
Oberon and RISC5 are the work of Niklaus Wirth, Jürg Gutknecht and Paul Reed
([projectoberon.net](http://www.projectoberon.net)). CIL is maintained by the
[Goblint](https://goblint.in.tum.de) project. The emulators descend from Peter De
Wachter's [oberon-risc-emu](https://github.com/pdewacht/oberon-risc-emu).

## License

[MIT](LICENSE) for this repository's own code. DOOM's code, the patches to it, and the
built blob and disk image are GPL-2.0-or-later; the disk image also carries Project
Oberon 2013 and the shareware WAD. [`THIRD_PARTY.md`](THIRD_PARTY.md) lists what derives
from other work and the terms it carries.
