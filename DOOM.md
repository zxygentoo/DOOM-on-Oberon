# DOOM on Oberon

Run DOOM on the Hardcaml RISC5 Oberon machine (`~/Projects/oberon-risc-hardcaml`,
Nexys 4 / XC7A100T @ 60 MHz) — as an Oberon command, on real silicon.

"An operating system should run DOOM." — the design brief, roughly.

---

## 1. Feasibility scorecard

| DOOM (1993) needs | Our machine | Verdict |
|---|---|---|
| ~25–40 MIPS integer (386DX/486SX class) | 60 MHz, CPI 1.37 on running-OS code ≈ 40+ MIPS | ✅ enough — Phases 9–10 accidentally built a DOOM-class core |
| 16.16 fixed-point mul w/ 64-bit intermediate | `MUL` + `H` register = the exact shape of `FixedMul`, 2-cycle DSP multiplier | ✅ near custom-built |
| 4+ MB RAM (zone ~6 MB + WAD ~4 MB) | Architectural map 1 MB; **physical PSRAM 16 MiB**; core address bus is already 24-bit (`RISC5.v:7`) | ⚠️ widen SoC decode only (2a) |
| 320×200×8 palette video | 1024×768×1-bit mono | ✅ **decided: 1-bit dithered** (see §2) |
| C toolchain | Oberon-07 only; no RISC5 C compiler exists | ❌ the long pole (track 1, §7) |
| Keyboard w/ press+release | UART (bring-up) / raw PS/2 scancodes (native) | ✅ with make/break framing (§6) |
| Mouse | — | **cut for v1** (keyboard-only is period-correct; DOOM autoaims vertically) |
| Sound | none (Nexys 4 has a PWM jack) | **cut** — graphics + gameplay = "runs DOOM" |
| 35 Hz tick | ms-counter MMIO | ✅ exists |

Performance estimate: assume DOOM's working set drops the 4 KB cache to CPI 2–3
→ ~20–30 MIPS ≈ 386DX-40 territory ≈ **10–20 fps at low detail**. Playable.
Two named risks, two levers: (1) naive compiler codegen costs 2–3× vs gcc -O2
— a reason to pick a compiler with a real register allocator (§4); (2) cache
lines are single-word, so texture/span streaming eats a miss every 4th
byte-load — the likeliest source of CPI worse than 3. The fps lever if it
disappoints: multi-word lines + CellRAM burst fills — touches neither DOOM
nor the core, and 2a's tag rework is the natural moment to leave room for it.

## 2. Locked decisions

1. **1-bit mono graphics, dithered.** No new video hardware — the existing
   1024×768 pipeline (with its Phase-10c BRAM framebuffer shadow absorbing all
   video bandwidth) is untouched. Ample prior art (Playdate, e-ink, Mac Classic
   ports). DOOM's smooth light gradients dither well under ordered/Bayer.
2. **No audio** (v1+). Cuttable without disqualifying the result. PWM jack
   exists if anyone ever cares.
3. **No mouse** (v1). Keyboard-only was the 1993 baseline (arrows/Ctrl/Space/
   Alt/Shift); no vertical aim exists; Compet-N keyboarders set records this
   way. Oberon's absolute-position mouse could do burst-turning later; never
   load-bearing.
4. **doomgeneric** as the port layer — DOOM reduced to six `DG_` hooks
   (init, draw frame, get key, ms clock, sleep, set-title no-op); allocation
   arrives through libc `malloc`, one big himem block. Critically, its API is
   `Create()` + `Tick()` — host owns the main loop — which maps 1:1 onto
   Oberon's scheduling model (§5).
5. **Delivery = Option B: kosher stub module + flat blob in himem** (§5).
   Option A (emit genuine `.rsc`, DOOM as a first-class module) is the polish
   pass; same compiler/runtime/blob, only the envelope changes.
6. **Retarget a small C compiler** host-side (§4): **lcc first** +
   hand-rolled hot loops — the classic port shape; vbcc stays the perf pass
   behind the frozen ABI (§7). No self-hosting ambitions.
7. **The blob never touches storage.** The stub loads blob + WAD into himem;
   the WAD reaches the blob as a pointer. Kills an entire SPI/SD driver in
   the blob — and the two-drivers-one-controller hazard of leaving the card
   in a state the Kernel driver doesn't expect (§3, §5).

## 3. Memory plan — himem, no kernel changes

The core already emits 24-bit byte addresses (16 MB); ROM (`0xFFE000`) and MMIO
(`0xFFFFC0`) already sit at the *top* of that space; `Cellram` already fronts
the full 16 MiB PSRAM chip. The 1 MB limit is purely board-SoC decode.

**2a (§7) = widen the decode, change nothing else:**
- board `Soc` address decode 20 → 24 bits (board layer only — `lib/` core stays
  byte-identical, Phase-8 proofs untouched);
- `Cache` tag width extended to cover the wider space;
- **stock Oberon kernel, unmodified** — Oberon keeps its 1 MB worldview; DOOM's
  code, stack, zone (~6 MB) and WAD (~4 MB) live in `[1 MB, 14 MB)`, memory the
  kernel/allocator/GC never touch. (`HIMEM.SYS` for Project Oberon. Fitting.)

WAD storage gotcha: the PO filesystem caps a single file at ~3 MB (64 direct +
12×256 indirect 1 KB sectors); `DOOM1.WAD` is ~4 MB. **Split it into ≤3 MB
byte-range chunk files** (plain slices, not valid WADs) in the stock FS; the
stub concatenates them into himem at init. Stock filesystem, stock transfer
tooling, zero SD-layer work — the blob never sees storage at all (§2.7). Raw
sectors past the FS partition remain the fallback if chunking ever chafes.

## 4. Toolchain — the long pole

- **Compiler: lcc first; vbcc is the perf pass.** lcc is the easiest retarget
  of any real C compiler (lburg tree grammar, ~1 k lines; the Fraser–Hanson
  book is a literate retargeting manual and its MIPS backend is nearly our
  template) — but it barely optimizes, so pair it with hand-rolled assembly
  for the famous hot list (§7, 1a): DrawColumn/DrawSpan/FixedMul cover ~half
  the frame, and Amdahl puts lcc+asm within ~25–30% of a good optimizer.
  Every 90s port shipped exactly this shape. vbcc (global optimizer, real
  register allocator) stays the drop-in upgrade behind the frozen ABI if fps
  disappoints. cproc/QBE is out (QBE is 64-bit-only); naive stack-machine
  codegen à la chibicc risks 3–5× — a floor lcc comfortably clears. RISC5 is
  a dream backend either way: 16 regs, ~20 instructions, one addressing
  mode. lcc is C89-only: the amalgamation pass carries the conformance
  burden, and the host reference build polices it (`-std=c89 -pedantic`)
  for free.
- **The ABI is the track-3 keystone (§7, 3a)** — register args, callee-saved
  set, frame pointer, varargs, struct return; neither the backend nor the
  hand-rolled 1a functions can be written without it, so it freezes first.
  With interrupts unused the blob can own R12–R13 internally: ~14 allocatable
  registers.
- **No linker; one tiny assembler.** Amalgamate doomgeneric into a **single
  translation unit** (PureDOOM proves DOOM amalgamates — and its rename pass
  is a ready-made map of the `static`-symbol collisions to expect). The
  compiler emits RISC5 asm text; the track-3 assembler/flattener (~300 lines,
  §7 3b) resolves labels, expands intrinsic calls (`BL FixedMul` inlines to
  `MUL` + `H` — lcc has no inline asm, so inlining lives in the assembler),
  and emits a flat blob linked at a fixed himem address (say `0x100000`).
  No relocation needed. Label resolution has
  to live somewhere — better a legible afternoon's tool with free listings
  than fixup passes hidden inside the backend. (Wirth's compilers never had a
  separate assembler; we nearly keep that.)
- **Codegen gotchas (the two real traps):**
  - **DIV semantics.** Two traps, not one. (a) RISC5 `DIV` is *floored*
    (verified in Phase 3a); C mandates *truncation toward zero*. (b) The
    divider sign-handles only the *dividend* — the hardware precondition is
    divisor ∈ [1, 2³¹−1] (`divider.ml`'s own qcheck encodes it); a negative
    divisor returns garbage, not floored results. So the runtime helper wraps
    both operands (negate-before / fix-after) and matches `%` to `/`. Jig
    vectors (§7, 1a): all four sign combinations, both operators.
  - **64-bit math.** Don't teach the compiler `long long`. Replace `m_fixed.c`
    wholesale: `FixedMul` = `MUL` + read `H` (the high word, natively, in 2
    cycles). `FixedDiv` is `(a<<16)/b` — a 48-bit dividend the 32/32 divider
    can't take directly — so a small software long division (~200–300 cycles,
    seedable from the hardware divider's `H` remainder). Fine: FixedDiv is
    orders of magnitude rarer than FixedMul.
- **Mini-libc**, ~1–2 k lines: `mem*`, `str*`, `sprintf`-ish (printf → UART),
  one-big-block malloc (DOOM zone-allocates internally), and a memory-backed
  `w_file` fronting the preloaded WAD (doomgeneric's WAD I/O is stdio-shaped
  via a pluggable `w_file` layer; ~50 lines).
- Base-relative data addressing (vbcc supports it — Amiga small-data mode) is
  only needed for Option A relocatability; the v1 fixed-address blob skips it.

## 5. Runtime architecture — stub module + blob

Reconciliation with Oberon's compiler-in-system model: Oberon's real contract
is the **object format + loader**, not ORP; and PO itself has always been
bootstrapped by host-side cross-compilation (the `.dsk` we boot was built on an
emulator). DOOM arrives the way Oberon's inner core arrives — a foreign binary
loaded by a small, legible loader written in the system's own language.

**The blob** (C, sealed, knows nothing about Oberon): exports
`Init(wad_addr, cfg)`, `Tick()`, `KeyIn(ev)`. Renders 320×200×8 (doomgeneric
`CMAP256` mode → palette-index buffer) into a himem back buffer; dither-blits
(256-entry luminance LUT → 4×4 Bayer → pack 32 px/word) into a target
rectangle it is *told*. PLAYPAL is *14* palettes (pain/item/rad-suit
flashes): `I_SetPalette` selects among 14 precomputed LUTs — full-screen
dither shifts, very visible in 1-bit, free juice — and gamma (DOOM's F11)
folds into the same LUTs, which matters because dithered 1-bit runs dark.
Talks only MMIO: timer, UART, framebuffer. **No storage, no SPI** (§2.7):
the WAD arrives as a pointer. Zero Oberon imports.

**The stub** (`DOOM.Mod`, Oberon-07, compiled in-system by ORP — fully
orthodox, ~50–150 lines): loads the blob (~1 MB — an ordinary FS file) and
the WAD chunks (§3) into himem; owns all storage I/O and all Oberon
citizenship.

**The boundary contract** (one page — frozen at 3a, proven by hello blob,
§7): blob header carries entry offsets +
a `.bss` range the stub zeroes; `Init`/`Tick` prologues switch to a himem C
stack (Oberon's stack budget is small; `R_RenderBSPNode` recurses) and
save/restore R12–R15 (MT/SB/SP/LNK) — trivial with interrupts unused, but
written down; `exit()`/`I_Error` return to the stub (flag + message over
UART), never halt; savegame/config writes are v1 no-ops (`M_LoadDefaults`
already tolerates a missing file).

Two modes, same blob (doomgeneric's Create/Tick split is exactly this seam):

- **v1 — fullscreen seize.** `DOOM.Run`: load, `Init`, loop `Tick` until quit,
  never returning to `Oberon.Loop` meanwhile (cooperative single-threading —
  a long-running command *is* the model). On exit: one viewer-system broadcast
  repaints the desktop (viewer state lives in the heap, only pixels were lost).
- **v2 — viewer + task citizenship.** `DOOM.Open` opens a normal `MenuViewers`
  viewer (`System.Close DOOM.Pause` menu); the frame handler translates input
  and recomputes the blit rect on resize; an **`Oberon.Task`** calls `Tick()`
  once per loop iteration. DOOM runs in a tile of the desktop, cooperatively
  scheduled, clock still ticking next door. ~60–100 ms per tick = sluggish but
  live UI during play; `DOOM.Pause` deinstalls the task. Closing the viewer
  restores neighbors via the normal protocol.

Blit cost (v1, 640×400 centered, 2×2 pixel-doubled): ~64 k source px × ~15 cyc
≈ 1 M cycles/frame ≈ 25% of clock at 15 fps. Affordable; un-doubled 320×200
corner render is the free fallback. Framebuffer stores ride write-through +
wbuf; video reads come from the 10c BRAM shadow — the video tax stays dead.

## 6. Input — press/release everywhere

DOOM needs key make/break (hold-to-move). Three paths, one queue in himem:

1. **UART (bring-up, day one):** raw serial has no key-up, but the sender is
   our own host-side serial agent → define a 2-byte make/break event framing.
   Doubles as the console: DOOM's `printf` scrolls out the same wire.
2. **Raw PS/2 scancodes via MMIO (v2 / native):** PS/2 natively speaks
   make/break (`F0` prefix). Bypass `Input.Mod` (it delivers translated ASCII,
   no key-up) — consistent with blob-talks-MMIO. Needs the PS/2 Pmod for the
   second port (controller already proven in @formal + cosim).
3. Oberon `Input` path: **not usable** for gameplay (no release events); fine
   for menu/viewer chrome in v2.

## 7. Plan — three tracks, one convergence

Two mountains and the rope between them: **track 1** compiles DOOM to RISC5
machine code; **track 2** makes the machine/OS ready to receive it;
**track 3** is the seam both anchor to — ABI, assembler, blob format, himem
layout. Track 3 goes first (days of work, and everything else bakes its
artifacts in); tracks 1 and 2 then run fully parallel. And because the
linker is `cat`, compiled `.s` and hand-written `.s` mix freely in one blob:
the C compiler doesn't *enable* the runtime, it *fills in* code and data
inside an envelope already proven end-to-end.

**Track 3 — the seam** (first; the freeze is the deliverable)

| | Deliverable | Verify |
|---|---|---|
| **3a** | ABI spec (args R0–R3, return R0, FP + callee-saved set, varargs — designed to lcc's shape, frozen before backend work) · asm syntax · blob header w/ version byte · the himem layout constants page | it's a spec: one page, reviewed, frozen |
| **3b** | ~300-line assembler/flattener: labels + one addressing mode + intrinsic call expansion (`BL FixedMul` → `MUL`/`H`/shift inline); no macros, no expression grammar | assembled output byte-diffs against hand-encoded words |

**Track 2 — the machine** (2a/2b start immediately; 2c needs 3a)

| | Deliverable | Verify |
|---|---|---|
| **2a** | 24-bit board decode + wide cache tags; himem visible | existing goldens green at old map; himem r/w test; boots unchanged |
| **2b** | Oberon-07 prototypes of the DG hooks: dither-blit on the real panel (LUT, Bayer look, the 25% budget), ms timer, UART key queue + host-side serial agent | eyeballs on silicon; measured blit cycles vs §5's estimate; key make/break echoed end-to-end |
| **2c** | stub loader: blob file + WAD chunks → himem (host-side chunk splitter included); header parse; `.bss` zero | loads a crafted image; himem contents verified |

**Milestone — hello blob** (closes tracks 2+3): a hand-assembled blob through
the full path — stub loads it, stack switches to himem, R12–R15 saved, writes
framebuffer + UART, restores, returns clean — on sim *and* hardware. Its
natural extension, the **test-jig blob** (run vectors, dump results), becomes
the standing harness track 1 plugs into. After this milestone, every failure
is content, not infrastructure.

**Track 1 — the content** (the long pole, now ringed by a proven harness)

| | Deliverable | Verify |
|---|---|---|
| **1a** | hand-rolled hot functions: `FixedMul`/`FixedDiv`, DIV/MOD fixup helpers, `R_DrawColumn`/`R_DrawSpan`, `mem*` | each runs in the jig in Cyclesim vs host reference — before lcc exists |
| **1b** | lcc RISC5 backend (lburg grammar + support functions; the Fraser–Hanson book is the manual, its MIPS backend nearly our template) | compiled jig blobs vs host: division across all four sign combos (`/` and `%`), call-heavy torture functions; every increment through the same jig |
| **1c** | single-TU amalgamation + C89 pass + mini-libc + C ports of the 2b prototypes + **host reference build** of the same TU | host build plays E1M1; pieces unit-tested in the jig |
| **1d** | first frame of E1M1 **in simulation** — harness preloads blob+WAD straight into the PSRAM model; pixel-exact framebuffer dumps via the visual-golden harness, a bring-up luxury no DOOM port ever had. (0.39 M cyc/s ≈ 10 s/frame is *steady-state*; `D_DoomMain` init is hundreds of M cycles ≈ tens of sim-minutes — don't debug a "hang" that is `R_InitTextures`.) Then v1 stub on hardware | sim framebuffer golden ≡ host-reference frame (same dither code, bit-identical); demo desync check; on-hardware E1M1 |

**Later** (each optional, independently landable): v2 viewer + task; Option A
`.rsc` envelope; PS/2 Pmod keys; mouse burst-turn; PWM audio; **vbcc backend
as the perf pass** — a drop-in behind the frozen ABI, and the 1a asm drawers
survive the swap.

The backend (1b) is still the biggest single piece — a C backend for the
world's cleanest 32-bit ISA remains the gentlest possible introduction to
compiler backends — but it's now the *last* thing standing instead of the
first long pole: by the time lcc emits its first function, the assembler,
loader, sim path and host oracle are all battle-tested, so any failure is
the backend's fault and nothing else's.

Cross-cutting oracle: the host build of the same amalgamated TU (ILP32-clean
via stdint) is both the debugger and the golden generator — and the IWAD's
built-in demos are deterministic, so a demo that plays without desync
(checksummed gametic state vs the host run) certifies DIV semantics,
fixed-point, and alignment in one shot. Cheap insurance against
silently-wrong arithmetic surfacing as "monsters walk through walls" three
phases later.

## 8. Open questions

- Compiler licenses: lcc's noncommercial terms are fine for v1; vbcc's
  license/registration story matters only if/when the perf pass happens.
- Exact himem layout: blob load addr, stack, zone size, WAD placement, back
  buffer — one page of constants, frozen at 3a (it's a seam artifact;
  everything downstream bakes it in).
- doomgeneric `CMAP256` + our little-endian packing — confirm buffer format at
  1c (RISC5 is little-endian, matches WAD; watch packed-struct alignment,
  though doomgeneric already carries fixes from ARM ports) — and confirm
  `I_SetPalette` is surfaced under `CMAP256` (may need a two-line doomgeneric
  patch; the 14-LUT dither depends on it, §5).

---

*Host repo: `~/Projects/oberon-risc-hardcaml` (Hardcaml design, board layer,
sim/verification harnesses). This repo: the DOOM arc — toolchain, runtime,
stub, blob. The machine work (2a) lands in the host repo's board layer.*
