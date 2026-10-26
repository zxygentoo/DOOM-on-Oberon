# Design

How DOOM runs on the Oberon RISC5 machine: what the machine had to offer, the decisions
that shaped the port, the memory plan, the toolchain, the runtime and the input path, and
how each piece is verified. The contract between the pieces is [`ABI.md`](../ABI.md);
how it was built, slice by slice with every measurement and dead end, is
[`build-log.md`](../build-log.md).

## The machine, against what DOOM needs

The machine is [oberon-risc-hardcaml](https://github.com/zxygentoo/oberon-risc-hardcaml):
Wirth's RISC5 in Hardcaml on a Digilent Nexys 4, 64 MHz, a 16 KiB cache in front of
16 MiB of PSRAM, a 1024×768 one-bit screen.

| DOOM (1993) needs | The machine | Verdict |
|---|---|---|
| ~25–40 MIPS of integer work (386DX/486SX class) | 64 MHz, about 1.4 clocks per instruction on the running OS | enough |
| 16.16 fixed-point multiply with a 64-bit intermediate | `MUL` leaves the high word in `H`: `FixedMul` is 6 instructions | a natural fit |
| 4+ MB of RAM (a 6 MB zone, a 4 MB WAD) | Oberon's map is 1 MB, but the board decodes all 24 address bits of the 16 MiB chip | DOOM lives above 1 MB |
| 320×200 8-bit palette video | 1024×768×1 mono, plus Halftone: a display mode that dithers an 8-bit window at scan-out | one-bit, dithered |
| a C compiler | Oberon-07 only; no RISC5 C compiler existed | this repository's |
| keys with press and release | raw PS/2 scancodes carry make and break | yes |
| a 35 Hz tick | the millisecond counter | yes |
| mouse, sound | — | cut |

The result: **15.0 frames a second on the board at 64 MHz**, presenting through Halftone
(the cycle-accurate model says 18.2; 8.9 with the software dither), and the timedemo
plays to exactly 5026 gametics, the count of the host build.

## Decisions

1. **One-bit graphics, dithered.** No new video path for the mono screen. DOOM's
   320×200 frame fills the whole panel at 3.2×3.84 — exactly the 4:3 CRT pixel aspect
   DOOM was drawn for — through ordered dithering against a 64×64 void-and-cluster
   blue-noise map (`bin/emit_bn64.ml`, σ 1.5): stable from frame to frame, without
   Bayer's crosshatch. Horizontally every output pixel gets its own decision; vertically
   each source line gets two threshold rows ("out2"), enough for DOOM's 8-pixel menu
   font. Luminance weights (150, 80, 26) instead of ITU-601's lift DOOM's pure-red text
   from ~26% to ~50% white without moving any gray, and gamma 2 is the default
   (`patch/c/0002`), since one-bit output runs dark. Two implementations make the same
   pixels: the software kernel (`libc/dither.c`, hand-scheduled in `lib/drawers.ml`) and
   the Halftone display mode, fed the same tables.
2. **No audio.** Graphics and gameplay are "running DOOM".
3. **No mouse.** Keyboard-only was the 1993 baseline; DOOM has no vertical aim.
4. **doomgeneric as the port layer.** DOOM reduced to six `DG_` hooks — init, draw
   frame, get key, the millisecond clock, sleep, window title. Its `Create()` + `Tick()`
   shape lets the host own the main loop, which is how Oberon schedules (below).
5. **A stub module and a flat blob.** `DOOM.Mod`, an ordinary Oberon-07 module compiled
   in the system by its own compiler, loads a binary blob — DOOM, compiled — into memory
   above Oberon's and calls into it. The blob knows nothing about Oberon. (Emitting
   DOOM as a genuine Oberon object file would be the polished envelope for the same
   blob; it was never needed.)
6. **An all-OCaml toolchain.** A C front end as an OCaml library, our own RISC5 backend,
   one shared definition of the instruction encoding (below). The escape hatch, never
   used: retarget lcc or vbcc onto the same ABI.
7. **The blob never touches storage.** The stub reads every file; the WAD reaches the blob
   as a pointer. No disk driver in the blob, and no second driver fighting the Oberon
   kernel's over the SD card.

## Memory

Oberon keeps its 1 MB world and its kernel unmodified; the kernel, the allocator and the
garbage collector never look above 1 MB. The board layer decodes the full 24-bit address
— 16 MiB of PSRAM — and DOOM's blob, its C stack, its 6 MB zone, the WAD and the Halftone
windows all live above 1 MB. The table is [`ABI.md` §8](../ABI.md#8-himem-layout-v1-the-constants-page).

The Project Oberon file system caps a file at about 3 MB (64 direct plus 12×256 indirect
1 KB sectors), and `DOOM1.WAD` is 4 MB. `bin/split_wad.ml` cuts it into plain byte ranges,
`doom1.wad.0` and `doom1.wad.1`; `DOOM.Mod` concatenates them back in memory and checks
the WAD's own directory before starting DOOM.

## The toolchain

- **Front end: goblint-cil 2.1.0.** It parses C as an OCaml library (`-std=gnu99`, an
  ILP32 little-endian machine description with `char` unsigned) and hands over an IR
  that is most of the way to three-address code: expressions side-effect free, types
  resolved. `Mergecil` merges DOOM's 80 translation units and the libc's into one
  program, renaming the few colliding statics. CIL has no code generator.
- **Backend** (`lib/fundec.ml`). Instruction selection straight to `Risc5_isa.instr`.
  Allocation is deliberately naive: register variables get fixed homes in the
  callee-saved R6–R11, locals past six spill to stack slots, expression scratch takes
  R0–R5 and whatever homes a function leaves free. A statement that needs more scratch
  than exists is flattened to three-address form and compiled again. Anything outside the
  ABI's types is refused, never miscompiled (`lib/check.ml`).
- **The two traps.** RISC5's `DIV` floors and wants a positive divisor; C truncates. `/`
  and `%` call helpers that wrap the hardware (`lib/runtime.ml`). And 64-bit arithmetic
  does not exist: `m_fixed.c`, DOOM's only 64-bit code, is replaced wholesale — `FixedMul`
  is a 6-instruction inline (`MUL`, then the high word from `H`), `FixedDiv` is 32-bit C
  (`libc/fixed.c`). doomcc skips `m_fixed.i` itself: host preprocessing spells `int64_t`
  as x86-64 `long`, which ILP32 sizes at 32 bits, so it would compile silently wrong.
- **The linker** (`lib/linker.ml`, `lib/blob.ml`). It works on `instr` lists, not text:
  labels and branches, the 2-word address pseudo, the `FixedMul` expansion, code/data/bss
  layout at the blob's fixed address, the header and checksum, the symbol map, and data
  words that hold addresses. No text assembler exists or is needed.
- **Hand-written code** is an OCaml eDSL (`lib/asm.ml`) over the same `instr` type, so it
  links with compiled code freely: the division and shift helpers and `setjmp`/`longjmp`
  (`lib/runtime.ml`), and the drawers (`lib/drawers.ml`) — the dither kernel,
  `R_DrawSpan`, `R_DrawColumn`, the Halftone frame copy. Each drawer replaces a compiled
  C function that stays in the tree as its specification.
- **Mini-libc** (`libc/`): `mem*`, `str*`, a bump `malloc`, `vsnprintf` and the printf
  family on the UART, memory-backed `fopen`/`fread` over the WAD, the glibc ctype seam —
  preprocessor-free C that doomcc compiles like DOOM's own units.
- **Performance** was chosen by measurement. Profiles found the frame in four functions;
  the levers that paid were `memcpy`'s word path, the hand drawers, moving the dither into
  scan-out hardware (Halftone) and a 16 KiB cache. Allocation beyond the naive scheme
  (local, linear-scan) and general inlining were priced and parked: their ceilings were a
  few percent ([`build-log.md`](../build-log.md)).

## The runtime

**The blob** exports three entries in its header (`ABI.md` §7): `Init(wad, shared)`,
`Tick()`, `KeyIn(event)`. Each is reached through a crt0 thunk that parks Oberon's
registers R6–R15, switches to the C stack above 1 MB, sets up the data base, and restores
everything on the way back. doomgeneric's `D_DoomLoop` runs initialisation plus one tick
and returns, so `Init` comes back and `Tick` is one frame. `exit()` — reached from DOOM's
quit and from `I_Error` at any call depth — stores a status in the shared page and unwinds
to the current entry with a `setjmp`-shaped jump, so control always returns to Oberon.

**The stub** (`patch/oberon/DOOM.Mod`) loads `doom.blob`, verifies its header, zeroes its
bss, loads and checks the WAD chunks, fills the shared page (WAD length, presentation
flags, the command tail) and plants the entries as procedure variables. Two
presentations of one blob:

- **`DOOM.Run`** seizes the machine: a loop that never returns to `Oberon.Loop`, polling
  raw PS/2 bytes between ticks — a long-running command is Oberon's model. With Halftone
  present (the stub checks its frame counter) the blob presents through it; without it
  (the emulator) the blob dithers into the framebuffer itself. At exit one broadcast
  repaints the desktop: viewer state lives in the heap, only pixels were lost.
- **`DOOM.Run -win`** is a citizen: an ordinary viewer, an `Oberon.Task` running one
  `Tick` per pass of the Oberon loop, the desktop live around it. The stub owns the
  Halftone rectangle for the viewer's lifetime and re-shapes it on resize. Halftone only.

**Presenting a frame.** On the software path `DG_DrawFrame` rebuilds the luminance table
when the palette changes and dithers the frame across the whole panel. On the Halftone
path it copies the finished frame into the pixel window — the renderer must never be
watched mid-frame — and uploads the luminance table on palette changes; the threshold map
and the geometry go up once.

## Input

DOOM needs press and release; Oberon's `Input` module delivers translated characters and
drops releases. PS/2 carries both natively (an `F0` prefix marks a release), so the stub
reads raw scancodes: the seize loop from the keyboard FIFO, the windowed mode through
`Input.SetSink`, a raw-scancode tap patched into `Input.Mod`
(`patch/oberon/Input.Mod.patch`) that is active only while the pointer is over the game.
One state machine translates both streams: letters stay ASCII (cheat codes need them),
arrows arrive `E0`-extended and the keyboard's fake-shift wrapper around them is
swallowed. Events reach the blob through a ring in the shared page (`ABI.md` §8).

## Verification

Every piece is checked against an independent implementation, and any two that disagree
localize a bug.

- **The differential jig** (`test/test_jig.ml`): about 250 C samples, each compiled by
  doomcc and run in the emulator, and compiled by host gcc (`-m32 -funsigned-char`, the
  target's data model) and run natively, over edge values and random arguments. Where
  gcc cannot be the oracle, self-checks state the expected value; refusals are pinned to
  their reason. The Runner also checks that callee-saved registers and the stack survive
  every call.
- **The host reference build** (`make ref`, plain gcc and SDL on the same patched
  sources): DOOM's built-in demo timed at **5026 gametics** — one tick of drift anywhere
  in 143 seconds of play changes the count.
- **Golden frames** (`make check`): the same `dither.c`, compiled by gcc into a headless
  host build, against the blob on the emulator — the framebuffer bit-identical at
  gametics 100, 1000, 2500 and 5000, and both runs ending at 5026.
- **On the booted OS** (`bin/run_dsk.ml`): the disk image boots in the emulator and a
  scripted timeline of keys and clicks drives `DOOM.Run` through play, quit and restore.
- **The cycle-accurate model** (`sim/`): the blob on the board SoC as it ships, cycles per
  tick, the parked frame bit-identical to the host golden on both presentation paths.
- **The board**: the timedemo at exactly 5026 gametics.

## Why CIL

The hardware is OCaml, so the toolchain is too. CIL is a maintained C front end that is
an OCaml library, with C99/C11 and GNU extensions; its expressions arrive free of side
effects, its types resolved, and `Mergecil` is the single-program amalgamation. A spike
before the choice was made parsed all 80 port-relevant units of the real tree, merged
them with ten static collisions renamed, and found 12 080 CIL instructions across 1 184
functions — the backend's actual workload — with the merged program still compiling
under host gcc.

It fits the grain of the host repository: a typed ISA next to the emulator, a
lockstep-proven oracle, differential testing as the house style. One `encode`/`decode`
serves compiler, linker and emulator, so the encoding cannot drift, and verification
reaches inside the compiler instead of stopping at the blob.

The honest cost: codegen quality and correctness are ours. Naive allocation was expected
at about twice optimal; the measured profile put most of the frame in a few loops that
were hand-written anyway. CompCert was out (a new ISA means new Coq semantics and proofs),
and the host reference build stays plain gcc on the original sources, so a front-end bug
cannot corrupt both sides of the diff.
