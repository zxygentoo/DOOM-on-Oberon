# DOOM on Oberon

Run DOOM on the Hardcaml RISC5 Oberon machine ([oberon-risc-hardcaml](https://github.com/zxygentoo/oberon-risc-hardcaml),
Nexys 4 / XC7A100T @ 60 MHz) — as an Oberon command, on real silicon.

"But can it run DOOM?" — Today, Oberon becomes a real OS!

---

## 0. How we work together (read this first)

**This is a learning project. Speed is explicitly *not* a goal.** The point
is for the human to learn compiler backends, systems programming, and the
craft of bringing a large C program onto a bare machine — deeply. We build
this **together — track by track, slice by slice, step by step.** Optimize
for understanding, not throughput.

Concretely, as the agent on this project you should:

- **Explain before building.** For each slice: first walk the problem — the
  CIL construct to lower, the ABI rule, the RISC5 encoding, the DOOM-side
  gotcha — then how it maps to our `risc5_isa` instrs and backend, *then*
  write code. Never drop a finished slice without the walkthrough.
- **Teach the "why."** Surface the compiler/systems reasoning: why CIL hands
  us side-effect-free near-three-address IR, why the register-allocator ladder
  is the perf schedule and not a nicety (Amdahl, §4), why RISC5 `DIV` floors
  where C truncates, why the blob never touches storage, little-endian
  packing, the himem stack switch. Treat each slice as a mini-lesson.
- **Small, reviewable increments.** One slice (or sub-block) at a time. Prefer
  a short diff the human can fully read over a large code dump. Stop at natural
  checkpoints and let them absorb / ask questions / drive.
- **Don't run ahead.** Do not jump to later slices or adjacent tracks
  unprovoked. The human sets the pace and is the driver; you are the
  pair-programming guide.
- **Pair the code with its spec.** When lowering a construct, keep the
  reference open — `ABI.md` for the ABI/linker seam, `risc5_isa`'s `.mli` for
  the instr type, the CIL typed AST, the doomgeneric source — map it
  construct-by-construct, and call out anywhere our choice departs from the
  obvious transliteration (and why).
- **Verify each step.** No slice is "done" until it passes the differential
  jig — our backend in the emulator vs host gcc (§7, 1b). Green tests are the
  unit of progress, not lines written.
- **Format is a pre-commit gate.** `.ocamlformat` (profile `janestreet`,
  copied from the host repo) sits at the repo root. Before staging any commit,
  run `dune fmt` on the `default` switch; never commit a tree that isn't
  fmt-clean — `dune build @fmt` is the check (green = clean). The vendored
  emulator formats itself behind its own project boundary — leave it pristine.
- **It's fine to go slow and re-explain.** If a concept needs more grounding,
  give it.

---

## 1. Feasibility scorecard

| DOOM (1993) needs | Our machine | Verdict |
|---|---|---|
| ~25–40 MIPS integer (386DX/486SX class) | 60 MHz, CPI 1.37 on running-OS code ≈ 40+ MIPS | ✅ enough — Phases 9–10 accidentally built a DOOM-class core |
| 16.16 fixed-point mul w/ 64-bit intermediate | `MUL` + `H` register = the exact shape of `FixedMul`, 2-cycle DSP multiplier | ✅ near custom-built |
| 4+ MB RAM (zone ~6 MB + WAD ~4 MB) | Architectural map 1 MB; **physical PSRAM 16 MiB**; core address bus is already 24-bit (`RISC5.v:7`) | ✅ **done (2a)** — decode widened; 16 MiB himem addressable |
| 320×200×8 palette video | 1024×768×1-bit mono | ✅ **decided: 1-bit dithered** (see §2) |
| C toolchain | Oberon-07 only; no RISC5 C compiler exists | ❌ the long pole (track 1, §7) |
| Keyboard w/ press+release | UART (bring-up) / raw PS/2 scancodes (native) | ✅ with make/break framing (§6) |
| Mouse | — | **cut for v1** (keyboard-only is period-correct; DOOM autoaims vertically) |
| Sound | none (Nexys 4 has a PWM jack) | **cut** — graphics + gameplay = "runs DOOM" |
| 35 Hz tick | ms-counter MMIO | ✅ exists |

Performance estimate: assume DOOM's working set drops the 4 KB cache to CPI 2–3
→ ~20–30 MIPS ≈ 386DX-40 territory ≈ **10–20 fps at low detail**. Playable.
Two named risks, two levers: (1) naive compiler codegen costs 2–3× vs gcc -O2
— why the backend's register-allocator ladder (§4) is the perf schedule, not
a nicety; (2) cache
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
6. **All-OCaml toolchain** (§4, §9 — spike-verified, `spikes/cil/`):
   goblint-cil front-end + our own RISC5 backend, sharing one ISA
   encoder with the emulator and core tests. Hand-rolled hot loops stay.
   Escape hatch if the backend stalls: retarget lcc or vbcc onto the same
   frozen ABI/assembler seam — nothing else moves. No self-hosting
   ambitions.
7. **The blob never touches storage.** The stub loads blob + WAD into himem;
   the WAD reaches the blob as a pointer. Kills an entire SPI/SD driver in
   the blob — and the two-drivers-one-controller hazard of leaving the card
   in a state the Kernel driver doesn't expect (§3, §5).

## 3. Memory plan — himem, no kernel changes

The core already emits 24-bit byte addresses (16 MB); ROM (`0xFFE000`) and MMIO
(`0xFFFFC0`) already sit at the *top* of that space; `Cellram` already fronts
the full 16 MiB PSRAM chip. The 1 MB limit is purely board-SoC decode.

**2a (§7) — ✅ LANDED 2026-07-05 — widen the decode, change nothing else:**
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

- **Compiler: goblint-cil front-end + our own RISC5 backend, all OCaml**
  (locked at §9's green gate; evidence in `spikes/cil/`). CIL hands the
  backend a gift-wrapped IR: expressions guaranteed side-effect-free
  (assignments/calls hoisted into explicit instrs over typed temporaries —
  most of the way to three-address code), types resolved, CFG attached —
  and `Mergecil.merge` *is* the single-TU amalgamation, spike-measured on
  the real tree (80/80 TUs, exactly 10 static collisions, auto-renamed).
  The backend owns instruction selection (a dream on this ISA: 16 regs,
  ~20 instructions, one addressing mode), the ABI, and a
  register-allocator ladder — naive → local → linear-scan — landable
  incrementally behind a correct-but-slow first cut, because the
  hand-rolled hot list (§7, 1a) carries ~half the frame regardless
  (Amdahl: naive ≈ 2× optimal overall, local ≈ 1.3×; every 90s port
  shipped the asm-hot-loop shape). Escape hatch, one sentence: if the
  OCaml backend stalls, lcc (easiest retarget in the business) or vbcc
  (optimizing) bolt onto the same frozen ABI/assembler seam — nothing
  else moves.
- **The ABI is the track-3 keystone (§7, 3a)** — register args, callee-saved
  set, frame pointer, varargs, struct return; neither the backend nor the
  hand-rolled 1a functions can be written without it, so it freezes first.
  With interrupts unused the blob can own R12–R13 internally: ~14 allocatable
  registers.
- **No linker; and no text assembler on the critical path.** The canonical
  form is `risc5_isa.instr` — a **host-repo, stock-OCaml** module: the instr
  ADT + `encode`/`decode` + inlinable field accessors, the single definition
  of the RISC5 encoding. It's shared by the compiler, the core tests, and —
  a sub-project of its own, **now landed** — the emulator's own decode (the
  accessor layer is designed so `single_step` adopts it at zero perf cost —
  spike-proven, ABI §6). The
  backend emits `instr` lists directly; the 1a hand-rolled functions are an
  OCaml eDSL over the same type — so compiled and hand-written code are the
  same kind of value and mix freely in one blob. The DOOM-repo "assembler"
  is then not a parser but an **instr-level linker**: resolve labels/branches,
  expand `LEA` and the `FixedMul` intrinsic (`instr list → instr list`
  passes), lay out code/data/bss, patch pointer-valued data initializers
  (absolute words, ABI §6), emit the header+checksum, dump a symbol
  map. The flat blob links at a fixed himem address (say `0x100000`), no
  relocation. Both text *views* — a parser (text→instr) and a mnemonic
  disassembler (instr→text) — are deferred/demand-driven; `[@@deriving show]`
  on `instr` is the free debug-print floor. (Wirth's compilers never had a
  separate assembler; ours is a data type.)
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
    orders of magnitude rarer than FixedMul. Census-verified at the spike:
    these two are the tree's *only* 64-bit sites, so the backend never
    represents a 64-bit integer; six cold float functions are the strays 1c
    excises (`spikes/cil/RESULTS.md`).
- **Mini-libc**, ~1–2 k lines: `mem*`, `str*`, `sprintf`-ish (printf → UART),
  one-big-block malloc (DOOM zone-allocates internally), and a memory-backed
  `w_file` fronting the preloaded WAD (doomgeneric's WAD I/O is stdio-shaped
  via a pluggable `w_file` layer; ~50 lines).
- Base-relative data addressing is only needed for Option A relocatability;
  the v1 fixed-address blob skips it — and since DB-relative is already the
  backend's global addressing mode (ABI §2), Option A stays cheap later.

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
artifacts in); tracks 1 and 2 then run fully parallel. And because compiled
output and hand-written code meet as lists of shared `risc5_isa` instrs — the
backend emits them, the 1a eDSL constructs them — they mix freely in one
blob: the C compiler doesn't
*enable* the runtime, it *fills in* code and data inside an envelope already
proven end-to-end.

**Track 3 — the seam** (first; the freeze is the deliverable)

| | Deliverable | Verify |
|---|---|---|
| **3a** | ABI spec (args R0–R3, return R0, FP + callee-saved set, varargs) · the assembler/linker contract (ABI §6) · blob header w/ version byte · the himem layout constants page | ✅ **`ABI.md` FROZEN v1 (2026-07-05)** — 6/6 register split, offsets 0–35, layout all locked; changes require a version bump |
| **3b** ◐ | ◐ **`risc5_isa` module in hand** — instr ADT + `encode`/`decode` + `[@inline]` field accessors (stock OCaml, zero-dep; the single definition of the encoding). Landed via its first consumer — the vendored emulator's `single_step` now decodes through the accessor layer (ABI §6, zero-cost). **Remaining:** hoist to a standalone host-repo module (shared with the backend) + the DOOM-repo **instr-level linker** over it (label/branch resolution, `LEA` + `FixedMul` expansion, section layout, header+checksum, symbol map, pointer-valued global initializers patched as absolute data words — ABI §6; s3.1's `Globals` census shows the DOOM tree needs them) + the 1a eDSL + `[@@deriving show]` listings; text parser and disassembler deferred | **module ✅:** round-trip invariants property-tested (`decode ∘ encode = id`; `encode ∘ decode = id` for canonical words — `test_risc5_isa.ml`) + decode/accessor path anchored to silicon (emulator-on-`risc5_isa` ≡ HardCaml core, 250k+-case lockstep; boot + visual goldens green on host `develop`, vendor pin `e36fcf0`, 2026-07-06). **Remaining:** (i) encode-side **typed lockstep** — `encode i` → core performs `i` (Phase-4 harness); (ii) **label torture** — random branch skeletons, every label lands on its tag; (iii) jig blobs **emulator ≡ Cyclesim ≡ silicon** from hello blob on |

**Track 2 — the machine** (2a/2b start immediately; 2c needs 3a)

| | Deliverable | Verify |
|---|---|---|
| **2a** ✅ | 24-bit board decode + wide cache tags; himem visible | ✅ **LANDED on `develop` (2026-07-05, `caf942d`)** — the three board masks (`Cellram`/`Cache`/`Framebuf`) widened to the full 16 MiB; `lib/` core byte-identical (Phase-8 proofs untouched). Goldens byte-identical (`0xb9bdbf56…`), `@bench_boot` mirror 0-mismatch, 5 himem unit tests green; timing closes (WNS +0.147 ns @ 60 MHz); boots clean on hardware. Physical `MemAdr[22:0]` pins + XDC were already wired → no top/XDC change |
| **2b** | Oberon-07 prototypes of the DG hooks: dither-blit on the real panel (LUT, Bayer look, the 25% budget), ms timer, UART key queue + host-side serial agent | eyeballs on silicon; measured blit cycles vs §5's estimate; key make/break echoed end-to-end |
| **2c** ◐ | stub loader: blob file + WAD chunks → himem (host-side chunk splitter included); header parse; `.bss` zero. ◐ the host-side halves exist (2026-07-08): the chunk splitter (`bin/wadsplit.ml`) and the header-parse/bss-zero protocol rehearsed by `test_blob` at the real addresses; the Oberon-side `DOOM.Mod` stub itself is unwritten | loads a crafted image; himem contents verified |

**Milestone — hello blob** (closes tracks 2+3): a hand-assembled blob through
the full path — stub loads it, stack switches to himem, R12–R15 saved, writes
framebuffer + UART, restores, returns clean — on the emulator, Cyclesim,
*and* silicon. Its natural extension, the **test-jig blob** (run vectors,
dump results), becomes the standing harness track 1 plugs into. After this milestone, every failure
is content, not infrastructure.

**Track 1 — the content** (the long pole, now ringed by a proven harness)

| | Deliverable | Verify |
|---|---|---|
| **1a** ✅ *(re-scoped)* | hand-rolled hot functions: `FixedMul`/`FixedDiv`, DIV/MOD fixup helpers, `R_DrawColumn`/`R_DrawSpan`, `mem*` — planned as pre-backend insurance ("each runs in the jig before the backend exists"); the backend went coverage-complete first, so only the *load-bearing* pieces are hand instrs: `FixedMul` = the ABI §5 intrinsic (1a.1) + the eDSL drawers `runtime.ml` (`__div`/`__mod`/`__udiv`/`__umod` s7 · `__lsr` sweep) and `__setjmp`/`__longjmp` (port.4). `FixedDiv` became C (`libc/fixed.c`, 1a.1), `mem*` the 1c.1 mini-libc, `R_DrawColumn`/`R_DrawSpan` compile through the backend like everything else. Hand-rolling those hot loops stays on the shelf as an *optional perf lever* (the alternative to the §4 allocator ladder), chosen by 1d's timedemo — the eDSL machinery is proven, the drawer deliberately unstocked | every landed piece jig-verified vs host: the §7-1a four-sign-quadrant division vectors live in s7's samples; m_fixed full-range vs the *genuine `int64_t` originals* (`gcc_extra`, 1a.1); setjmp/exit in port.4's |
| **1b** ✅ *(coverage; allocator ladder open)* | the OCaml backend: CIL (gnu99 pin, RISC5 32-bit machdep, `Mergecil.merge`) → shared `risc5_isa` instrs → blob; ABI. Built on **two axes** — feature coverage (the *slice ladder* below): **COMPLETE `97397c2`** (2026-07-08) — 1202/1240, every reachable fn compiles, the 38 refusals all unreachable-or-replaced; and allocation quality (naive → local → linear-scan, §4): **open by design** — the spilling rungs (perf 1–4) landed so nothing *refuses*, but codegen is still the naive fixed-home allocator (store/reload redundancy; `DG_DrawFrame` ~2× the §5 blit estimate; the port layer's volatile-by-construction debt). Local/linear-scan re-enter only when 1d's timedemo numbers pick the lever | compiled jig blobs vs host: division across all four sign combos (`/` and `%`), call-heavy torture functions; **random-C-snippet differential** — our backend in the emulator vs host gcc; every increment through the same jig — final state **234 samples / 11 030 cases green** |
| **1c** ✅ | `Mergecil` single TU (spike-proven, `spikes/cil/`) + mini-libc + C ports of the 2b prototypes + **host reference build** (plain gcc on original sources — CIL stays target-path-only). The merge is **live** (every whole-tree doomcc run merges the 82 TUs + the libc TUs); mini-libc **complete** (1c.1–1c.3 — nothing libc-shaped remains undefined); the 2b C ports **subsumed by port.1–port.4** (`dither.c`, `doomgeneric_oberon.c`, the blob entries; the §6 *host-side serial agent* is track-2 tooling, still open on that ledger). **Host reference build ✅ `14f92c7`** (2026-07-08) — `host/Makefile`: plain gcc `-std=gnu99 -O2` + SDL2, the TU list read from the vendor Makefile's `SRC_DOOM` exactly as preprocess.sh reads it (one source of truth), platform TU swapped xlib → SDL; no `FEATURE_SOUND`, no `CMAP256`, no mouse (upstream has none) — the reference build carries the port's feature surface. `host/fetch-doom1.sh` pins the shareware WAD (md5, 4 196 020 B, repo root — also 1d's chunk-splitter input). Verified: E1M1 plays interactively; headless `-timedemo demo1` completes — **5026 gametics, the first desync-oracle constant** — with patch 0001's integer-tenths fps in first live use. The oracle *instrumentation* (CMAP256 + `dither.c` golden-frame dumper, gametic checksum) is 1d harness work | host build plays E1M1 ✅; pieces unit-tested in the jig ✅ (the libc/port samples) |
| **1d** ◐ | first frame of E1M1 **in simulation** — harness preloads blob+WAD straight into the PSRAM model; pixel-exact framebuffer dumps via the visual-golden harness, a bring-up luxury no DOOM port ever had. (0.39 M cyc/s ≈ 10 s/frame is *steady-state*; `D_DoomMain` init is hundreds of M cycles ≈ tens of sim-minutes — don't debug a "hang" that is `R_InitTextures`.) Then v1 stub on hardware. ◐ **the emulator leg RENDERS (2026-07-08)** — `bin/doomrun.ml`: plays the stub (blob at `BLOB_BASE`, WAD at `0xA00000`, SHARED page, bss zero per header), UART console on stdout, deterministic synthetic ms clock (default 44 000 steps/ms ≈ 60 MHz/CPI 1.37), Init/Tick through the real crt0 thunks, PGM frame dumps + FNV hashes, self-loop-trap detection. **Full `D_DoomMain` init completes (63.6 M instrs, Init → 0); TITLEPIC renders dithered into the exact §5 centered 640×400 rect; 400 Ticks clean; the E1M1 attract demo plays and renders in-game 3D frames.** First contact found 3 real bugs, each now a permanent gate: (1) the §8 WAD window was 1 716 B too small for the real shareware WAD — window end `0xE00000 → 0xE01000` (edited in place: the ABI has no consumers outside this repo yet); (2) **a live miscompile**: `materialize_addr`'s big-offset arm freed the base register before the two-instruction `load_const`, which landed ON it and doubled the offset — `&global[var]` as a value past the 16-bit immediate horizon (fopen's `&__handles[h]`; plain accesses ride the 20-bit mem-op offset and never see it) — jig sample `biga` fails-before/passes-after; (3) vsnprintf lacked *integer* precision (`%.3d` → `STCFN33`, HU_Init's font lump miss) — `vsn5` diffs it against genuine glibc. jig 236 samples / 11 130 green | sim framebuffer golden ≡ host-reference frame (same dither code, bit-identical) — **open**; demo desync check (gametic checksum vs host, demo1 = 5026 gametics) — **open**; timedemo fps — **open**; Cyclesim leg + on-hardware E1M1 — **open** |

**1b slice ladder** — the *coverage* axis: which C constructs compile, built one
reviewable vertical at a time under the naive allocator, each trusted only once it matches
gcc in the differential jig (§9). Allocation stays naive across all of these; the
naive → local → linear-scan ladder (§4) is the *later* perf pass, whose first rung is
spilling (the ">12 live values" refusals). The live worklist is `doomcc` itself —
`dune exec bin/doomcc.exe -- spikes/cil/out/i/*.i` prints, per merged program, how many
functions compile and a histogram of *why* the rest don't, each bucket a pending slice.
The code: library `doomcc_core` (`lib/`: `Check` — the refusal channel + ABI §4 type bans ·
`Frontend` — CIL parse/machdep/merge · `Globals` — static-storage placement + data/bss
image · `Fundec` — per-function compilation); the differential jig lives in `test/`
(`runner` = exec half, `test_jig` = the diff), the driver in `bin/doomcc.ml`.

| slice | constructs | status |
|---|---|---|
| **s1** | straight-line integer leaves — arithmetic, bitwise, shifts, casts, unary neg/not | ✅ `79bc806` |
| **s2** | control flow — if/else, while, for, && / \|\| short-circuits (CIL → nested if), multiple returns | ✅ `bed04e4` |
| **s3** ✅ | memory, in three sub-slices: **s3.1** scalar int globals/statics — `Globals` placement (DB-relative offsets, natural alignment, LE data+bss image, *tolerant per-global skip* so one bad global refuses only the functions touching it) + one-instr `LDW`/`STW` off DB + runner data segment/R13 (crt0-in-miniature) · **s3.2** the address calculus — `gen_addr` folding lval chains (deref / index / field) into base reg + residual constant (rides free in the 20-bit mem-op offset), `&global`, array decay, `ptr±int`, `ptr−ptr` (pow-2 sizes), const-index folding, `CompoundInit` · **s3.3** sub-word — `char` via `LDB`/`STB` (the ABI §1 char-unsigned payoff), `short` composed from 2×`LDB` (no halfword mem-ops exist), narrowing-cast masks | **s3.1 ✅ `9d24263`** (2026-07-06) — jig 26 samples / 1300 cases; 155→175 fns, 695 globals, 287 skipped. **s3.2 ✅ `d6118ac`** (2026-07-06) — jig 41 samples / 2050 cases green; 811 globals placed (162 KB image), 171 skipped; the 42-fn `ptr±int`/`ptr−ptr` bucket absorbed. Compiled *dipped* 175→166 — the now-honest sub-word-param gate catching shapes s3.1 silently miscompiled (green tests can't vouch for un-sampled forms; the gate must be airtight). Course-corrections banked: `&local`→s4 (a leaf has no frame to point into); pointer ordered compare (`q<end`, which CIL lowers to *unsigned*)→s5. **s3.3a ✅ `e5a1cee`** (2026-07-06) — `char` via `LDB`/`STB`, the ABI §1 char-unsigned payoff (LDB zero-extends, STB truncates — both free); entry + cast narrowing. The jig's gcc oracle gains `-funsigned-char` so it models *our* target — it flagged the signed-char-default divergence itself (the diff doing its job). **s3.3b ✅ `34c439f`** (2026-07-06) — `short` + signed `char`: no halfword mem-op exists, so a 16-bit access is *composed* from 2×`LDB`/`STB` (little-endian), signed/unsigned widening factored into `narrow_to`/`narrow_home`. jig 59 samples / 2950 cases green; 181→**227 fns**, 880 globals (326 KB image), 102 skipped — **no sub-word bucket remains; the s3 memory ladder is done.** **s4 (calls — 547 refused, the next mountain) next.** |
| **s4** ✅ | calls — the ABI frame (§3) over the new **`Linker`** (`resolve` lifted from one function to a whole program, ABI §6). The slice where the register split goes *live*: a `BL` clobbers R0–R5 + H + flags, so values live across a call move to callee-saved R6–R11 and a callee saves exactly the callee-saved regs it writes (+ LNK if non-leaf). Five sub-slices: **s4.1a** the callee *shape*, no calls — prologue/epilogue save/restore used R6–R11, return via `B LNK` (`To_reg 15`); `Runner` gains a stack (SP) + an LNK sentinel; Fundec still returns `instr list` · **s4.1b** the call + `Linker` — arg marshalling (evaluate each arg → `STW` to the §3 home area → `LDW` R0–R3, so evaluation and register placement decouple: no parallel-move puzzle), `BL` a named callee, result in R0; non-leaf homes migrate to R6–R11 · **s4.2** stack args + FP (args 5+ at `FP+16..`) · **s4.3** address-taken locals → FP-relative stack slots (`vaddrof`; `&local` deferred from s3) · **s4.4** aggregates by value (struct args stack-copied, struct return via hidden pointer) | **s4.1a ✅ `8365900`** (2026-07-06) — real frames; the `Runner` plays caller (seeds R6–R11 sentinels + SP, asserts both survive on return), so every sample now also verifies the callee-saved contract; a forced `regpress` sample drives 4 real saves. **s4.1b ✅** (`68606a2` Linker refactor · `d6e8b34` the call) — jig 66 samples / 3300 cases green incl. `fib` recursion; **227→447 fns compile**, the 547-fn `function call` bucket absorbed. As scoping predicted it *split*: top refusal is now 193 `too many regs (>6)` — **spilling (§4 perf pass) is the next big lever** (also revealed: 104 misc-expression forms, was 7). **s4.2 ✅ `4ffd482`** (2026-07-07) — stack args, both sides. Callee: >4 params → FP = entry SP, args 5+ read at `FP+16..` into homes (FP saved as a frame slot, introduced here — s4.3 reuses it). Caller: `makes_call`→`call_arity` sizes the outgoing area to `4·max(4,widest call)` so outgoing stack args (`SP+16..`) clear the saves — a flat 16 would let the arg store clobber saved R6; the marshaller loads only R0–R3, args 5+ stay stored. jig 71 samples / 3550 cases green — `sum6`/`nl5` (callee reads) · `u5`/`u6` (caller passes 1/2 stack args, position-weighted) · `both5` (both mechanisms in one frame); **447→456 fns compile**, the `>4 params` + `>4 call args` buckets gone. The FP choice was census-backed: DOOM has **zero `alloca`/VLA** (80 TUs, `-Wvla` clean against a positive control), so SP is provably fixed and FP is *disciplinary* — kept for ABI §3 frame-idiom fidelity + s4.3 reuse, not correctness. Top refusal stays 203 `too many regs (>6)` — **spilling is the next lever**. **s4.3 step 1 ✅ `6237a74`** (2026-07-07) — aggregate + address-taken *locals* get a word-aligned slot in a new **locals region** (between the outgoing area and the saves). **SP-relative, not the s4.2 FP** (the entry above expected FP reuse): a slot's FP-offset subtracts the frame size, which body codegen fixes only *after* the save set is known — but the slot is addressed *during* body codegen; the SP-offset (`outgoing+slot_off`) is known upfront, and the census-proven fixed SP makes it safe. One insert carries it — `gen_addr`'s local case returns `(SP, slots_base+off)`, the mirror of a global's `(DB, off)`, so the fold layers fields/indexes/deref on top (⇒ `&local`, array decay, `t[i]`, `p.f` for free); `Lval`/`Set`/call-result fast-paths route slotted locals to memory, `&param` refuses to step 2. jig 76 samples / 3800 cases green — `aql` (address-taken scalar aliasing `*p`) · `larr` · `lstruct` · `cptr` (sub-word slot) · `outp` (`&y` escaping to a callee, slot + outgoing area coexisting); `la`/`al` rejects retired. **456→458 fns**; the `&local` + `local-used-as-memory` buckets gone (most freed fns hit a *next* blocker — expression forms, `>6` regs). **s4.3 step 2 ✅ `bc0478b`** (2026-07-07) — address-taken *params*: the same slot machinery + a prologue spill. The wrinkle — a slotted param **keeps its register home** (a slotted *local* skips one) so the leaf's positional placement (param *i* in R*i*) survives; skipping it would shift every later param off its arg register (`amid`'s `c` would read R1 but arrive in R2). The prologue `STW`s the home into the slot once it lands, so a stack param (i≥4) comes free — `param_setup` already loaded it there. Entry-narrowing skips slotted params (the slot's own sub-word load narrows on read). jig 79 samples / 3950 cases green — `aptr` (scalar param alias) · `amid` (the *middle* of three params slotted, position-weighted so a disturbed home surfaces) · `outparam` (`&param` escaping to a callee). **s4.3 done** — no address-taken/aggregate bucket remains (`&local`, `local-used-as-memory`, `address-taken parameter` all gone); **458 fns** (the 3 freed hit a *next* blocker). **Spilling (§4 perf pass) is now the top lever — 211 fns (`>6` 201 + `>12` 10).** **s4.4 ✅ `9117e23`** (2026-07-07) — whole-struct copy, the *only* by-value aggregate op in DOOM. The census collapsed the slice: **0** struct args + **0** struct returns across 80 TUs (every aggregate travels by pointer), so the planned hidden-pointer-return / stack-arg-copy ABI is dead code — it stays a clean refusal, relabeled *census-absent* and now cross-checked to fire **0×** at whole-tree compile (census ⟺ compiler). The real surface is **16** whole-struct assignments; `gen_struct_copy` is a **byte-wise** memory copy (`materialize_addr` both ends, unrolled `LDB`/`STB` over the compile-time size) — byte-wise *on purpose*, since these structs are often sub-word-aligned (`mapthing_t` 5 shorts → align 2 / 10 B; `struct color` 4 chars → align 1; `ticcmd_t` has shorts) and `LDW`/`STW` would mask the address; word-copy-when-≥4-aligned is a noted later optimization these 16 cold sites don't warrant. Hooked as the first `Set` case (aggregate-typed dst), so `a=b` · `*dp=*sp` · `arr[i]=s` all reduce to two base addresses + a byte shuttle. jig 84 samples / 4200 cases green — `cps` (local slot) · `cpg` (global/DB-relative, promoted from a now-obsolete reject) · `cpp` (`*dp=*sp`) · `cparr` (indexed source) · `cpsh` (the align-2, 6-byte case). **s4 (calls) is done** — s4.1a/1b/2/3/4 all in; **458 fns compile**. The lone dominant lever left is **spilling** (`>6` regs, 211 fns) — the §4 perf pass, a different axis (allocation quality, not feature coverage). |
| **s5** ✅ | the odds — `!` / compare as a 0/1 value, unsigned ordered compares (incl. pointer `<`/`>`, which CIL lowers to unsigned — signed is exact in our 24-bit address space, so this is where pointer-walk `while (q < end)` unblocks), `switch`, `continue` (CIL → goto) | Sub-sliced like s3/s4: **s5.1** compare/`!` as a value · **s5.2** unsigned ordered compares + unsigned `>>` · **s5.3** `switch` · **s5.4** `continue`. **s5.1 ✅ `4ad0d81`** (2026-07-07) — a comparison or `!` as a 0/1 *value* (not a branch). RISC5 has no set-on-condition, so `bool_from_flags` branches over two immediate loads (`B<cond> l_true` · `MOV 0` · `B l_end` · `l_true: MOV 1`), reusing `rel_cond` — the C-relop → `(cond, neg)` map, hoisted up to be the single encoding shared with the branch form `gen_cond`. Two sites: a `gen_expr` case for the six relops (`SUB` for flags → materialize; ordered unsigned defers to s5.2 with `gen_cond`'s guard) and `!x` = `(x==0)` (`MOV` sets Z → materialize `Eq`). `d` is allocated *after* the operands free, so it never widens their live range — register pressure being the top naive-alloc blocker. jig 93 samples / 4650 cases green — all six relops (every `(cond, neg)` pair; full-range args incl. INT_MIN/MAX catch a flipped neg through SUB overflow) · `lnot` · `notnot` (`!!`) · `cmix` (materialized bools as arithmetic operands, trichotomy). `binop_instr`'s relop case split (relops → intercepted-upstream internal error; `&&`/`\|\|` as a value → clean refusal, CIL lowers them). **458 → 511 compile (+53, the biggest single-slice jump)** — the `!` (96) and compare-as-value (8) buckets gone. **s5.2 ✅ `c354cba`** (2026-07-07) — unsigned ordered compares: signed and unsigned `</>` read different condition codes off the same `SUB`. Verified the RISC5 carry convention against the emulator (`Sub` sets `flag_c (s > b_val)` = borrow), so after `SUB a,b` **C is set iff `a<b` unsigned** — below = `Cs`, below-or-same = `Ls` (`C\|Z`), `>=`/`>` their negations; signed stays the overflow-aware `N≠V`. `rel_cond` gained `~signed`; new `compare_unsigned` (unsigned int *or pointer* → unsigned — the pointer-walk unblock, exact because 24-bit addresses never set the sign bit). Both the value (`gen_expr`) and branch (`gen_cond`) forms drop the old refusal guard and pass the signedness — one path, both. jig 100 samples / 5000 cases green — `ultv`/`ulev`/`ugtv`/`ugev` (all four orderings) · `uc` (unsigned *condition*, promoted from a stale reject) · `pcmp` (pointer `<`) · `uhi` (`a < 0x80000000u`, the deterministic distinguisher the equal-pair edges can't give — `a=1` → 1 unsigned, 0 if wrongly signed). Disassembly: `BCS`, not `BLT`. **511 → 527 compile (+16)** — the 48-fn unsigned-ordered bucket gone. **s5.2b ✅ `3358f26`** (2026-07-07) — unsigned (logical) `>>` = `ROR` + mask (no LSR on RISC5): rotate right by n, then mask off the n bits ROR wrapped into the top. Constant count only; the whole-tree confirms **0 variable-count `>>` in DOOM** (every unsigned shift is a constant — FRACBITS &c.), so it covers the tree. Masks past a 16-bit immediate (n=1 → 0x7FFFFFFF) ride a register via `load_const`. jig `usr1`/`usr16`/`usr31` (mask sizes; edge x=−1 separates logical from ASR) · `usrmix`; 527 → 528. **s5.3 + s5.4 ✅ `6409492`** (2026-07-07) — switch, goto, continue, all through one new **per-statement backend label** (`label_of_stmt`, placed at `gen_stmt` entry for any labeled stmt). **switch** = compare-and-branch dispatch chain (`SUB` value vs each case → `BEQ` to that case's label; the case/default labels ride the body statements, so fall-through is natural statement order and break exits); the loops stack became `(int option * int)` — a loop carries continue+break, a switch only break (its `None` passes continue through to the enclosing loop). **goto** = `jmp` to the target statement's label, forward or backward — arbitrary goto just works because the naive allocator's fixed homes mean merge points need no reconciliation. **continue** = nearest loop's continue target (CIL lowered for-loop continue to a goto before the increment, so it rides the goto path; while/do stays `C.Continue` → loop top). **The jig caught the trap** — switch came out 99-mismatch, every case landing on default: CIL leaves `stmt.sid = -1` until a CFG pass, colliding every label; fixed by numbering statements per-function in `compile` (local numbering — we don't need succs/preds; cases + goto targets are the same physical statements as the body). jig `sw1`/`swf`/`swd`/`swnb` (dispatch · fall-through · shared labels + return-in-switch · no-default) · `wc`/`fc`/`gt`/`gtb` (while-continue · for-continue-via-goto · forward/backward goto); the `cn` reject became `fc`. **528 → 569 (+41)**, switch/goto/continue buckets gone. **s5 done — the coverage ladder s1–s5 is complete; every remaining blocker is a deferred track (spilling §4, the 3b linker, `/`·`%` helpers ABI §5, the 64-bit 1a sites).** |
| **perf 1** ✅ | the *allocation-quality* axis (§4) — a different lever than the s1–s5 coverage ladder: relieve the naive allocator's fixed-home exhaustion (the `>N` regs refusals) by spilling excess variables to memory | **spilling rung 1 ✅ `c3f8c1e`** (2026-07-07) — naive alloc gave every register-eligible var a fixed home and refused when the homes ran out — the `>6` regs bucket, the single biggest blocker (201 fns). The insight: a spilled local is *just a slotted local* (s4.3), and `gen_addr`/`Lval`/`Set`/call-result already route `ctx.slots` through memory — so spilling is "when the home pool is exhausted, `add_slot` the excess local instead of refusing", everything downstream unchanged; the slot is the var's single canonical location, so merges need no reconciliation (exactly like a home). Scoped to **non-leaf locals** — the clean case: non-leaf scratch is fixed at R0–R5 regardless of home count, so spilling never starves expression evaluation. Params stay homed (spilling one needs a prologue store — deferred; and the tree has **no `>6`-param fn**, so it costs nothing); leaf spilling deferred (a leaf grows scratch *above* its homes → needs a scratch reservation first, and it's only 10 fns). `add_slot` lifted out of `alloc_slot` so s4.3 slots and spills share it. jig 115 samples / 5750 cases green — `many` (2 params + 11 locals, 7 spilled across a call) · `sloop` (spilled locals live across a call *in a loop*) · `mixs` (an address-taken slot and spill slots sharing the locals region); disassembly confirms the ABI §3 frame (homes R6–R11, spilled locals `SP+16..`, outgoing args `SP+0..`, saves above — plus the naive store/reload redundancy the *next* rungs collapse). **569 → 614 (+45)** — the 201-fn `>6` bucket gone; freed fns redistributed into their next blockers (expression forms 160→243, global-init 84→102). Only the 10 leaf `>12` remain on this axis. **Top blocker is now `expression form` (243) — a grab-bag due a census.** |
| **s6** ✅ | the *expression-form remainder* — a census (2026-07-07) split the post-s5 "expression form" grab-bag (243 fns) cleanly into **sizeof** (72) and **string literals** (171, `CStr`); nothing exotic (no `?:` — CIL lowers it to if/else; no float/enum consts — banned/folded upstream). Both are forms CIL hands the backend *unfolded* | **sizeof ✅ `b273af5`** (2026-07-07) — CIL leaves `sizeof` unfolded on purpose (a later type-changing pass might rewrite the type); by the backend it's a compile-time `size_t` constant, so one grouped `gen_expr` case folds all three forms — `SizeOf t`→`bitsSizeOf t/8`, `SizeOfE e`→same on `typeOf e` (operand *unevaluated* — no VLAs in DOOM by census — so only its type is taken, never codegen'd), `SizeOfStr s`→`length+1`. No type check (sizeof of a banned type is still a valid number, not a use). **The jig caught a target divergence** — `szptr` = 4 (ours, ILP32) vs 8 (gcc, x86-64 LP64) for `sizeof(int*)`: the oracle was modeling the wrong data model, fixed with **`-m32`** (the ILP32 companion to s3.3a's `-funsigned-char` — int/long/pointer all 32-bit), whole suite re-verified 0 regressions. jig `szint`/`szptr`/`szst`/`szarr`/`szstr`. **614 → 628 (+14)**; the "expression form" bucket is now *purely* string literals (181). **string literals ✅ `7c0198c`** (2026-07-07) — a `CStr` is a char* to anonymous static bytes. Interning in `Globals` (the sole owner of static-data placement): after the GVar pass, a `nopCilVisitor` scans all expressions (bodies *and* global initializers) for `CStr` and appends content+NUL after the placed globals, deduplicating via a new `strings : string→offset` map on `Globals.t` (NUL rides free — pre-zeroed image; a literal past DB's +512 KB reach stays uninterned, tolerant-skip). `Fundec`: `gen_expr (CStr s)` = `add_const DB off` — exactly the `&global` address form. jig 124 samples / 6200 cases green — `sidx` (index) · `slen` (iterate to the NUL — terminator proven) · `spass` (literal as a call arg, the printf shape) · `smulti` (two distinct literals); pointer values never cross the diff (different address spaces), only dereferenced bytes — char unsigned both sides. Dedup verified: `"hi"`×3 + `"bye"` interns exactly 2, packed. **628 → 747 (+119, the biggest single-slice jump — 63% of the tree)** — the expression-form bucket is *gone*; strings were the most pervasive blocker (error messages, printf, level/cheat strings); image +30 KB → 357 KB. **s6 done.** Top blocker is now **global initializers (133)** — its string-pointer half (`char *name = "E1M1"`) reuses this exact interning map, the rest (`&global`, fn ptrs) is genuine 3b-linker address-patching; also surfaced: a 4-fn `>6 params` bucket (previously hidden behind string refusals — the earlier "no `>6`-param fn" census claim was scoped to then-reachable functions). |
| **s7** ✅ | division — `/` `%` → Runtime helper calls (ABI §5, "never a bare DIV"), bridging the two §4 DIV traps; the slice that **opens the 1a eDSL drawer** (hand-rolled helpers as `Linker.obj`s over the same `risc5_isa` instrs the compiler emits — hand-written and compiled code link freely) | ✅ **`8bd84f7`** (2026-07-07) — **`lib/runtime.ml`** (new): `__div`/`__mod` (signed truncating) + `__udiv`/`__umod`. Semantics: C truncates, RISC5 DIV *floors* (H = rem ∈ [0,divisor)) — equal unless signs differ *and* inexact, then trunc = floor+1, C-rem = H−divisor. Envelope: divider sign-handles only the *dividend*, divisor ∈ [1,2³¹−1] — so `b<0` negates divisor then quotient (after the fix: trunc is sign-symmetric, floor isn't), `b=0` (UB) → deterministic 0, `b=INT_MIN` (un-negatable) its own branch; **no helper issues an out-of-envelope DIV**. `__mod` rides `a%b = a%|b|`. Unsigned: **`DIV'` (u-variant) divides unsigned exactly for any dividend** (`risc.ml:320`) → `__udiv` is 9 instrs — one `DIV'` + the top-bit divisor path (q ∈ {0,1} by one carry compare) = ABI §5's fast/slow split, literally. **Fundec — the div-area protocol** (`gen_helper_call2`): CIL's no-calls-in-expressions gift covers only *source* calls; this BL is backend-generated, mid-expression, live temporaries in helper-clobbered scratch. A `calls_runtime_helper` *visitor* pre-scan (division hides in any expression position) forces non-leaf + a 32 B div area between outgoing and locals (can't share outgoing — a division inside a call arg would clobber marshalled args). Protocol: evaluate both operands *first* (nested divisions finish their area use before ours), store both + free (the marshaller's decoupling), save busy scratches, `LDW R0/R1`, `BL`, park result fresh, restore; `div_base=-1` without a scan hit → mismatch fails loud. Non-pow-2 `ptr−ptr` → byte gap through `__div` (exact by C's same-array guarantee ⇒ sign-safe). jig 145 samples / 7250 cases green — the §7-1a vectors: 4 sign quadrants × both ops · `dfull`/`mfull`/`dm` (full-range, the C99 identity) · `dmin`/`dbymin` (INT_MIN both roles) · `udf`/`umf`/`ubig` (both unsigned paths) · `ppd`/`pnd` (non-pow-2 ptrdiff ± gap; `ppd`+`d` promoted from retired rejects) · `dmix` (live scratches across the BL) · `ddn` (nested). Runtime links into every jig program as the real blob will. **628 → 846 (+218, the biggest jump — 71% of DOOM)**; `/`·`%` (116) + ptr−ptr (15) buckets gone, ~87 co-blocked fns freed. Silicon note: helpers verified against the lockstep-proven emulator DIV; the 3b emulator ≡ Cyclesim ≡ silicon pass gives the floored-semantics claim its final check. Top blocker now **global initializers (151)**. |
| **s8** ✅ | global initializers — the census split the 151-fn "needs a link-time address" bucket into three separable problems, two of which were never linker work: **typed NULL** (the macro expands to a cast *of* a cast — a typed pointer cast around the void-pointer cast of 0 — which `word_of_init`'s one-level peek missed; most `= NULL` inits refused on it), **float-folded fixed-point constants** (the automap tables: `(fixed_t)(.867 * 65536)`, compile-time double math under an int cast), and **data relocs** (ABI §6's "pointer-valued data initializers as absolute words") | ✅ **`478c09f`** (2026-07-07) — `int_core` recurses through cast stacks to the integer core; `float_const` evaluates constant double exprs with the truncating cast (`fxn` pins −45875, not floor's −45876 — no float reaches the blob). **Relocs**: `ptr_target` takes string literals (the s6 intern map, as planned) + `&global`/decay with constant Field/Index chains (`bitsOffset`); `Globals.t` gains `relocs : (image off, DB-rel target) list` — image holds 0, consumer patches `DB+target` (jig at `Runner.data_base`; 3b linker at the blob's base). `from_file` → **three passes** (place → intern → serialize) so forward refs + string offsets exist at serialization; pass 3 runs to a **fixed point** — a placed-but-unserializable global (fn-ptr table) is un-placed, so a referrer's already-resolvable `&it` re-fails *honestly* next round instead of a reloc silently pointing at a zeroed gap (refuse, never miscompile). jig 156 samples / 7800 cases green — `spi`/`sl` (string-ptr; `sl` promoted) · `rp`/**`wp`** (read + *write-through* — real aliasing via the reloc) · `ra`/`rm` (decay, `&arr[2]` addend) · `rt` (relocs + NULLs in one CompoundInit) · `sptr` (in-struct) · `nul` · `fxc`/`fxn`; new `usefp` reject holds the fn-ptr line for 3b. **846 → 925 (+79) — 78% of DOOM**; 938 globals place (+58), 730 relocs, skipped 102→44, GI bucket 151→20 (fn ptrs + &extern, genuinely 3b). Top blocker now **call result to a non-local lval (63)**. |
| **s9** ✅ | call result to any memory lval — `g = f()`, `*p = f()`, `s.f = f()`, `arr[i] = f()` | ✅ **`f73a4c9`** (2026-07-07) — a 10-line general case replacing the slotted special case + the refusal. The hazard the refusal guarded: after the `BL` the result sits in **R0, the lowest scratch — exactly what the destination's address calculus allocates first**. Fix: claim R0 busy for the store's duration; `gen_addr` then allocates from R1 up. The claim **composes with the s7 div-area protocol for free**: `arr[x % 4] = f(i)` puts a `__mod` call *inside* the destination while R0 is live — the protocol saves/restores the claimed R0 like any live value (the `cidx` sample). jig 161 samples / 8050 cases green — `cres` (global dst, direct `Call(Some g)`) · `cptr2` (`*p=f(i)`) · `cfld` (field) · `cidx` (composition) · `cch` (sub-word dst). **925 → 983 (+58) — 83% of DOOM.** The remaining 201 split: ~104 converge on the **3b linker + mini-libc** (externs 47, indirect calls 37, GI residue 20), 36 = the 64-bit **1a `m_fixed`** sites, 34 unions (the last plain coverage slice), ~16 allocator odds/ends — after unions, every remaining fn waits on a *subsystem*, not a construct. |
| **s10** ✅ | union globals — the last plain coverage slice | ✅ **`4d912a5`** (2026-07-07) — a **3-line relaxation** of `check_placeable`: everything downstream already worked (Check recurses union members; Fundec slots any `TComp`; `bitsOffset` puts union fields at 0; `gen_struct_copy` is byte-wise; a union `CompoundInit` names one field, the pre-zeroed image gives C's rest-stays-zero for free; size/align = CIL machdep max-over-members). DOOM's unions: `actionf_t` (fn-ptr variants), `intercept_t`'s thing/line — same-width scalars. jig 166 samples / 8300 cases green — `ur` (bss union, LE punning: defined here, both sides LE + every access a real load/store) · `uwr` (first-member init) · `thr` (union-in-struct, the thinker shape) · `upr` (an s8 reloc *inside* a union init) · `ulc` (union local, slotted). **983 → 989 (+6) — 84%**; the 34-fn bucket gone, `thinkercap`/`intercepts`/`null_sector`/`dummy_mobj` place. Only +6 because most union-touchers also touch `states[967]`, whose fn-ptr inits made the s8 fixed point *un-place* it — touchers migrated to the GI bucket (20→36), the machinery being honest. ⚠️ image now **403 KB of the 512 KB DB reach** — 3b should pack bss/reclaim skip-gaps. **The coverage era ends here**: remaining refusals wait on the 3b linker + mini-libc (~130), the 64-bit 1a `m_fixed` sites (36), allocator odds/ends (~20). |
| **3b.1** ✅ | code addresses — the code half of the pointer story (a function has no address until layout; `Call` dodged it PC-relatively, but a function *pointer* is an absolute address in a register or a data word) | ✅ **`54ae25c`** (2026-07-07) — **Linker**: new frag `Addr of reg * string`, symbolic until resolve, expanding to the load_const MOV-high/IOR pair — **fixed 2 words** even for small addresses (frag sizing must never depend on resolved values); `link ~code_base`; `sym_addr` for reloc patching; `resolve_obj` → `concat_map`. **Globals**: `reloc_target = Data of int \| Code of string` — a fn-ptr initializer records the *symbol*; unknown names fail loud at link. **Fundec**: `&f` → Addr frag; **indirect call** — `fexp = Lval(Mem e)` is the function lvalue whose value IS the address, evaluated *between* the arg stores and the R0–R3 loads with **R0–R3 claimed** (s9's trick, four wide) so the target register sits above them; then `BL To_reg` (emulator-confirmed: register-target link branch sets LNK, jumps to the byte address). jig 171 samples / 8550 cases green — `icall` (fn-ptr global init) · `lcall` (`&f` local) · `cbk` (callback — the action-function shape) · `tcall` (**table dispatch — the `states[]` shape**) · `ical5` (indirect + stack arg); `callptr`/`usefp` rejects retired. **989 → 1108 (+119) — 94% of DOOM**; 980 globals place, **2 skipped** (was 44), `states[967]` places (1280 relocs). Honest caveat: doomcc doesn't *link* yet — a Code reloc naming an uncompiled fn fails only at 3b.2's real link; the gate moved where it belongs. Remaining 76: 64-bit 36 (1a `m_fixed`) · externs 11 (mini-libc) · allocator 19 · float 6 · bitfield 3 · var `>>` 1. |
| **3b.2** ✅ | the blob envelope — section layout at BLOB_BASE, the frozen ABI §7 header, checksum, symbol map; `doomcc -o` emits a real file | ✅ **`9673025`** (2026-07-07) — **`doom.blob` exists**: 517,512 B at `0x100000` — code 357 KB · data 160 KB · **bss 242,836 B reserved (spike estimated ~245 KB — nearly exact)** — inside the §8 cap. **Globals** gains the data/bss split: placement reorders (initialized → strings → uninitialized) so the image's zero tail IS the bss range (`data_size` the boundary); the file carries only data, the stub zeroes bss per the header. **`lib/blob.ml`**: `layout` (base \| header 64 B \| code \| data \| bss) + `emit` (magic/version/lengths/entries/checksum at the locked offsets); `base` parameterized — ABI's `0x100000` for the machine, `0x40000` in the test (the emulator models 1 MB; the 24-bit widening is a pending vendor patch — same math, one constant). **`test_blob.ml`** rehearses the stub: header verified *from the file bytes alone*, bss **poisoned-then-zeroed per the header** (provably load-bearing), the entry reached via the header's own field; the one stated dishonesty — DB set from layout — disappears when the thunks land. **doomcc links whole-program**: 87 undefined symbols → 1-word self-loop traps + the printed list = **the mini-libc worklist** (libc · six `DG_` hooks · `__builtin_va_*` · ~35 still-refused fns); 1199-symbol map dumped. Entries 0 until 3b.3's crt0 thunks. |
| **3b.3** ✅ | crt0 entry thunks — ABI §7's boundary protocol made real | ✅ **`3525b76`** (2026-07-07) — **`lib/crt0.ml`**: the spec's thunk shape verbatim, ~30 eDSL words — park Oberon's R6–R15 in a save area, `SP = STACK_TOP−16` (o32 home-area fold), `DB = data base`, `BL` the C entry (args untouched in R0/R1), restore, `B LNK`. The saving **chicken-egg** (storing R6–R15 needs a base register, but every high register is Oberon's) resolves via **R5** — outside the save contract, not an arg register; LNK saved as R15 and restored before the final `B LNK`. Save area = 40 B at bss end (stub-zeroed; ONE area serves all three thunks — cooperative single-threading). **`Crt0.size` is a constant**: every baked value loads via the fixed 2-word form so the code section is sizable *before* layout exists (the Addr-frag discipline), assert-checked. **`test_blob` loses its stated dishonesty**: the loader sets only what a stub's BL would (R0/LNK/PC-from-header); DB+SP belong to the thunk — and **R6–R14 sentinels are asserted bit-exact after the excursion into C** (Oberon's world provably survives). doomcc thunks each entry whose C symbol exists (`__crt0_*`); the DOOM blob still emits entries 0, correctly — Init/Tick/KeyIn are 1c's to write. **Track 3b is functionally complete** (LEA/`FixedMul` expansion rides with 1a's `m_fixed`): every failure past this point is *content* — mini-libc (1c, worklist printed at every link) · 64-bit `m_fixed` (1a) · small allocator/float residue. |
| **1c.1** ✅ | mini-libc part 1 — the no-varargs core: `mem*` · `str*` · `toupper`/`abs`/`atoi` · one-big-block `malloc`/`calloc`/`realloc`/`free` | ✅ **`0a16de7`** (2026-07-07) — **the libc is just another TU**: `libc/mini.c` (~215 lines, preprocessor-free — Frontc parses it directly), 21 symbols, merged by Mergecil like any DOOM unit; the bump arena reads `__heap_base`/`__heap_end` externs the *environment* binds (`libc/heap_doom.c` = §8's spare+zone rows; the jig binds emulator RAM). **The jig at its best**: 14 samples where *our memcpy, compiled by our backend, in the emulator, diffs against real glibc* — memmove overlap both ways · strncpy NUL-padding · strstr empty-needle · sign-normalized strcmp (magnitude unspecified — now an authorship rule) · calloc zeroing · realloc prefix · malloc alignment. **185 samples / 9250 cases green.** Lessons: (1) **Mergecil is nominal** — the .i files' glibc protos spell `size_t` as `unsigned long`, so mini.c typedefs it to match ("two distinct globals" otherwise); (2) that broke the **gcc oracle** (`-m32` headers say `unsigned int`) — the driver now declares printf/strtol directly, no includes; (3) **my own s7 semantics bit the samples**: `b[i % 6]`, negative `i` → negative index, UB the diff caught 3×. Whole-tree: 82 TUs, **1129/1205 compiled**, **undefined 87 → 67**, blob 520 KB. Remaining 67: printf/varargs (the `__builtin_va_*` compiler slice) · stdio/w_file · host-header artifacts (`__ctype_b_loc` &c., a re-preprocess hygiene slice) · ~35 still-refused DOOM fns. |
| **1c.2** ✅ | varargs — the stdarg builtins (compiler) + `vsnprintf`/`snprintf` (libc) | ✅ **`34be1e0`** (2026-07-07) — **the builtins must never become real calls** (a BL to va_start would clobber what it asks about; they'd been compiling into trap calls). CIL probe drove it: `va_start` arrives with *only* `ap` → anchor = `FP + 4·n_formals` (variadic callees take FP unconditionally); `va_arg` arrives pre-lowered `(ap, sizeof t, &dst)` with dst's `&` **special-cased by CIL** (no vaddrof → dst keeps its register home → the new `store_lval` helper, the s9 dichotomy extracted); size≠4 refuses (promotions make legal variadic args one word); cursor advance via a fresh register (`p` may BE ap's home). **The ABI payoff: zero prologue cost** — the s4.1b marshaller always stored every arg to the home area, so the whole list is already contiguous at `FP+0..`: §3's "varargs for free", cashed. **libc**: `vsnprintf`/`snprintf` (~130 lines) — flags/width/`%s`-precision/`l h` no-ops/`d i u x X c s p %`, glibc-corner-compatible on purpose; emitters share state via `sn_t*` (9 params would refuse under naive alloc — the gate shaping the code). jig 192 samples / 9600 cases green — `vsum`/`vmix`/`vshift` (our va-codegen vs **gcc's own varargs**, same headerless source: the 7-arg register/stack boundary, the FP+8 anchor) · `vsn1–4` (our formatter vs **glibc's snprintf**: INT_MIN, truncation, sign-aware zero-pad, precision). Whole-tree: **1134/1210**, undefined **67 → 62**; va-using DOOM fns now inline correctly instead of trapping. |
| **1c.3** ✅ | memory-backed stdio + UART console — §2.7 "the blob never touches storage" made concrete | ✅ **`4dc0dc2`** (2026-07-07) — **`libc/stdio.c`**: `__file_register(name, base, size)` (the port layer names the WAD's himem range at Init; `w_file_stdc` fopen/freads it none the wiser); read-only fopen family (`"w"`/`"a"` → NULL — the §5 v1 no-op contract), glibc-exact `fread`/`fseek`. **`FILE` stays incomplete** — the tree carries glibc's complete 32-field `_IO_FILE` (the merge error "32 ≠ 4 fields" was the teacher; nominal-Mergecil lesson #3), so the cursor lives in a private `__mfile_t` cast at the boundary. **Console**: printf family → `vsnprintf` → RS232 UART Oberon-style (status bit 1 @ `0xFFFFFFCC`, data @ `0xFFFFFFC8` — the *sign-extended* addresses the emulator dispatch and the 24-bit bus agree on); the bare jig emulator has no serial, so jig samples avoid the console (1d's harness attaches one). Polite refusals: remove/rename fail, mkdir pretends, `sscanf` zero-conversions stub (v1 has no config file → no live callers). `__builtin_bswap16/32` in mini.c — **signatures probed from CIL's builtin registry** (`short(short)`/`int(int)`). jig gains a **self-check mode** (the registry has no glibc counterpart): `sc1`/`sc2` verify hand-computed constants — registry→open→read→3 whences→EOF semantics→failed-seek-doesn't-move→two live handles. 194 samples / 9605 cases green. Whole-tree: **undefined 62 → 35**, 1167/1232, blob 532 KB. **No libc remains in the missing list**: 27 gate-refused DOOM fns (64-bit/float/leaf-spill) · six `DG_` hooks (the port layer) · `exit` (shared-page slice) · `__ctype`/`__errno` (re-preprocess hygiene). |
| **1a.1** ✅ | `m_fixed` replaced wholesale — the §4 second trap, and **a live miscompile found and killed**: the tree's `FixedMul` had been compiling *silently wrong* (MUL then a shift of the LOW word — H unread), because host-preprocessed `.i` files spell `int64_t` as `long` (x86-64 stdint.h), which ILP32 legitimately sizes at 32 bits — a preprocessing-provenance trap the type gate cannot see (nothing 64-bit remains to refuse). Source-level census re-confirmed the spike: **m_fixed is the tree's only `int64_t` user** — poison contained to the two functions always slated for replacement | ✅ **`6354115`** (2026-07-07) — **`FixedMul` = the ABI §5 intrinsic, realized**: `Call "FixedMul"` expands *inline at Linker resolve* — `MUL` (high word lands in H natively) · `MOV'` from H · `LSL/ROR/AND/IOR` repack of the middle 32 bits — 6 instrs clobbering **exactly R0/R1/H/flags** (the spec's shape verbatim, a strict subset of a call's clobbers); `frag_width` knows the expansion (deterministic layout), `is_intrinsic` keeps undefined scans honest, intrinsic-address fails loud. **`FixedDiv` = `libc/fixed.c`**, C with no 64-bit value: doomgeneric's saturation guard + ONE hardware division (integer part) + 16 restoring steps (fraction) — magnitudes unsigned (`0u-x` handles INT_MIN), sign last, guard bounds q < 2³⁰; ~200 cyc. **doomcc hard-skips `m_fixed.i`** (printed note — un-forgettable). Jig gained **`gcc_extra`** (oracle-side-only definitions): `fxm`/`fxd` diff our 32-bit machinery against the *genuine `int64_t` originals* full-range; `fxmi`/`fxdi` pin the unit identities; `fxc2` runs intrinsic + C division in one frame; `fxd` masks `a≠INT_MIN` (the original's abs-overflow quirk — we don't diff UB). 199 samples / 9855 cases green. Whole-tree: 1161/1225; FixedMul **inline at all ~139 sites** (absent from the map, +694 words); undefined steady at 35 — categorized: allocator residue 18 (of which the 9 leaf-spill fns are doomgeneric's host-video scaling, likely *dead for our port*) · float 5 (3 constant-foldable, 2 dead by locked decisions) · bitfield 2 (byte-aligned `:8` → degenerate byte access when needed; `I_SetPalette` is load-bearing for the dither LUTs) · var-`>>` 1 · `DG_` six + `exit` (the port slice) · `__ctype`/`__errno` (hygiene). |
| **1a.2** ✅ | constant-float fold — the automap unblocked | ✅ **`86cb28d`** (2026-07-07) — `gen_expr`'s cast case tries the s8 evaluator first: a compile-time constant under an int-family cast — crucially a constant *double* expression, the `(int)(1.02*FRACUNIT)` automap idiom — folds to a literal, truncating toward zero. **No float reaches runtime; the §4 ban stays airtight for everything live** (non-constant falls through, runtime floats still refuse). `int_core` became **width-exact** on the way: its cast recursion had skipped integer casts untruncated — fine for initializers (slot width truncates at write), wrong for *values* (`(char)300` must fold to 44); narrowing now wraps as the machine will. The scoping probe: of the five float fns, AM_LevelInit/AM_Responder are constants-only ✓ folded; `G_CheckDemoStatus` fps math is runtime (source-patch later); `SetVariable`/`V_DrawMouseSpeedBox` dead by locked decisions (no config, no mouse). jig 203 samples / 10055 cases green — `ff1`–`ff4` (constant mul/div, width-exact narrowing, negative truncation; gcc folds the same with real doubles). Whole-tree: 1163/1225, **undefined 35 → 33 — the automap compiles**. |
| **perf 2–3** ✅ | spilling rungs 2–3 — **the unified register model**: one rule replaces three refusals: *every function gets ≥ 6 scratch registers* | ✅ **`a0d0a42`** (2026-07-07) — compact shape (homes from R0, zero-cost frames) survives only for leaves with ≤6 register candidates; everything else — non-leaves and **demoted big leaves** — takes the split shape: homes R6–R11 · locals past six spill (rung 1) · **params past six spill** (rung 2: first six formals take the homes ⇒ a spilled param always arrives on the stack, prologue routes `FP+4i`→slot via R5) · **scratch widens to unused home registers** (rung 3: a 2-param fn gets 9 temporaries). Demoted leaf: pays R6+ saves, keeps LNK-free return; arrival moves keyed on `compact` not `leaf`. **The jig caught the model's bug** (142 fails, snprintf, multi-digit only): the widened range made the div-protocol's busy-scan "save" the permanently-busy homes — six saves overflowed the 6-slot div area *into the locals region* (`STW R11,[SP+48]` = `slots_base`). The fix proved the protocol's true contract: **only busy caller-saved R0–R5 need saving** — callee-saved scratches survive helpers (ABI §5: bodies touch R0–R3+H) and real callees (s4.1a) alike; div area = 32 B for a *proven* reason now. jig 207 samples / 10255 cases green — `p7` (demoted 7-param leaf, spilled param position-weighted) · `p8` (two spilled params across a call) · `ldeep` (14-candidate leaf demoted; **runner sentinels verify the new save obligation**) · `sdeep` (7+ live temps — over the old pool, inside the widened one). **1179/1225 compiled, undefined 33 → 18** (V_CopyRect · automap drawer · HUlib/STlib · all nine scalers · F_DrawPatchCol · FindNearestColor land). Honest residual: **3 fns exhaust even 12 regs** (`M_Responder` `S_AdjustSoundParams` `wipe_ScreenWipe`) — true expression-temp spilling or a CIL simplify pass, deferred by name. **The remaining 18 undefined**: those 3 · the **port-layer nine** (`DG_` six + `exit` + `__ctype`/`__errno`) · bitfield 2 (`I_SetPalette` load-bearing — byte-aligned `:8` degenerate case) · runtime-float 3 (`G_CheckDemoStatus` patchable; 2 dead by locked decisions) · `PadRejectArray` (var-count `>>`). **Next: the DG_ port slice** — landed as port.1–port.4 below. |
| **port.1** ✅ | DG_ port slice 1 — the four trivial hooks + **the key-ring contract** | ✅ **`59ea5eb`** (2026-07-07) — `libc/doomgeneric_oberon.c` (upstream's platform-file naming): `DG_GetTicksMs` (ms counter at sign-extended `0xFFFFFFC0`, the stdio.c UART convention — and *volatile holds by construction* under naive alloc, every deref a fresh LDW; a noted debt for a future caching allocator) · `DG_SleepMs` (wrap-correct unsigned spin — v1 is the fullscreen seize, and the emulator detects exactly this ms-counter idle-spin) · `DG_SetWindowTitle` (the contracted no-op) · `DG_GetKey` + `DG_KeyEnqueue` — *both halves* of the §8 SPSC ring in one reviewed file: free-running u32 head/tail masked at use (empty `h=t`, full `h−t=256`, exact across rollover), 2-byte events = the §6 wire framing verbatim (i_input's `TranslateKey` is the **identity** — the sender owns all translation, the blob never sees a scancode). ABI §8 gains the ring discipline as a §10 non-breaking clarification — the five sentences stub and blob meet at. `__shared_base` joins the `__heap_base` environment-binding pattern. Runner: the synthetic ms clock ticks 1 ms/1024 steps, so `slp`'s real assertion is *termination*. jig 211 samples / 10263 — `kr1` (FIFO + both event bytes) · `kr2` (head/tail seeded `0xFFFFFFFE`: slots 254, 255, 0 across the u32 rollover) · `kr3` (300 offered, exactly 256 accepted) · `slp`. Also fixed pre-existing: **`dune runtest` failed `Not_found` on clean HEAD** — the libc sources were never test deps (invisible from the sandbox; the suite only ever ran via `dune exec`); `test/dune` glob_files fixes it *and* re-runs the jig when libc changes. undefined 18 → 14. |
| **port.2** ✅ | `-DCMAP256` — **the tree was in the wrong video mode** — + the byte-aligned `:8` bitfield | ✅ **`6c43a62`** (2026-07-07) — preprocess.sh ran bare `gcc -E`, and i_video.c expects CMAP256 via CFLAGS: the `.i` tree had been building the *truecolor* path all along (`cmap_to_fb` load-bearing in the undefined list was the tell). `-DCMAP256`: pixel_t = palette index, `colors[256]`/`palette_changed` exported for the dither LUTs; coverage came out **bit-identical** across the mode switch — the only novelty CMAP256 exposes is exactly the bitfield struct. Part B: DOOM's entire live bitfield surface is `struct color { uint32_t b:8,g:8,r:8,a:8; }`, and LSB-first little-endian allocation makes a byte-aligned `:8` field **one addressable byte** — LDB/STB, the s3.3 machinery, no read-modify-write exists. One predicate (`Check.byte_bitfield`: width 8, `bitsOffset` ≡ 0 mod 8) + three consumers: the type gate (placement rides the same check — `colors` places, skip list down to `mouse_acceleration`) · `gen_addr`'s Field guard (a cast pointer can reach a struct no declaration gate saw — the `rjp` reject proves that path fires; the existing `bitsOffset/8` fold then addresses it untouched) · `classify_access` consults the lval's **final Field before the declared type** — a bitfield lval's type is the declared uint32, which would misclassify Word: an STW clobbering three neighbors per write. A fourth site caught by reading, not failure: `serialize_init` sized a field's write from `bitsSizeOf ftype` → a `:8` initializer would have written *four bytes over the neighbors*; one-byte slot type substituted, `bf6` the witness. jig 217 / 10563 — `bf1` (**the layout pin**: fields written, raw bytes read back through `char*`, diffed vs gcc `-m32` — CIL machdep ≡ gcc LSB-first, proven not assumed) · `bf2` (neighbors as witnesses) · `bf3` (the I_SetPalette shape) · `bf4` (store-truncation) · `bf5` (signed `:8`) · `bf6`; rejects `rj3`/`rj48`/`rjp` hold the narrowed gate. 1187/1230; undefined 13 → 12 (`I_SetPalette`, `cmap_to_fb`, `I_GetPaletteIndex` land — cmap_to_fb as dead code, by mode). |
| **port.3** ✅ | `DG_DrawFrame` — the dither-blit, compiled by our own backend | ✅ **`cb43359`** (2026-07-07) — the kernel is its own file **`libc/dither.c`** with zero externs/MMIO/includes *on purpose*: the whole file rides the jig as oracle-side source too (`gcc_extra`, the m_fixed mechanism), so the **exact shipped kernel diffs against host gcc** — 1d's "same dither code, bit-identical" contract cashed at function level. Pipeline: `colors[]` (gamma pre-applied by I_SetPalette) → 256-byte luminance LUT (ITU-601 weights, sum 256) → 4×4 Bayer thresholds `m·16+8` (lum 0 always black, 255 always white) → 1-bit, 2×2-doubled with **one dither decision per source pixel** (§5's ~64k/frame budget; the doubled 320×200 pattern is the Playdate look — per-output-column dithering is the 2× quality knob if 1d's dumps disappoint); "14 precomputed LUTs" simplified to one-LUT-on-`palette_changed`. Geometry verified against the emulator (render.ml): fb **bottom-up**, bit 0 = **leftmost**, base `0xE7F00` — the kernel takes dst = the rect's top-left word *in screen coords* + a **signed stride** (machine −32, jig small positive: the flip is a parameter, not a special case); the centered 640×400 rect is perfectly word-aligned (origin `583·32+6`, 20 words). Upstream: `-DDOOMGENERIC_RESX/Y=320x200` → `fb_scaling=1`, I_FinishUpdate degenerates to a per-line copy — the doubling happens in the blit, not as a byte-doubled 256 KB intermediate. Three verification axes (a diff can't catch wrong-but-deterministic — both sides run the same C): `dd1`/`dd2` (shipped-kernel checksums, all four Bayer rows, negative stride) · `kd1` (hand-computed words: `0xFFFF0000` pins LSB-leftmost, `0xCCCCCCCC` pins Bayer row 1, both strides mirror-identical) · `kd2` (two full 320×200 `DG_DrawFrame`s against a sentinel-fenced fb: exact rect coverage + the palette_changed protocol; Runner gains `?steps`). jig 221 / 10667. Honest caveat: 11 candidates → demoted leaf, inner-loop spills → expect ~2× the §5 blit estimate until an allocator rung or a 1a hand-roll; 1d's cycle counts pick the lever. undefined 12 → 11. |
| **port.4** ✅ | the blob entries `Init`/`Tick`/`KeyIn` + setjmp-shaped `exit` — **the DG_ port slice is complete; the header entries go live** | ✅ **`8ccf3fc`** (2026-07-08) — reference-reading resolved the architecture: doomgeneric's patched `D_DoomLoop` runs init + *one* tick and **returns**, so Init genuinely comes back and Tick is one clean frame; the only non-returning path is `exit()` (I_Quit → atexit chain → exit(0); I_Error → UART message → exit(−1)) at arbitrary call depth ⇒ §7's "never halt" is a **setjmp-shaped unwind**. Runtime gains `__setjmp`/`__longjmp` (the 1a eDSL's second drawer, 11 instrs each): a jmp_buf on this ABI is exactly the callee-saved state R6–R12/SP/LNK (9 words; DB is crt0-constant), the double return just a register reload — and under naive alloc it is *C-clean, not merely classically clean*: locals live in homes, so longjmp restores them to setjmp-time values. `exit` → SHARED+12 (0 → 1 clean-quit map, negatives pass through) + unwind to an env **re-armed at every entry** (a returned entry's env points into a dead frame). Init: arm (an I_Error during D_DoomMain returns the status as the error code) → `__file_register("doom1.wad", wad_addr, SHARED+28)` — the §2.7 WAD-as-pointer moment; +28 is a new §10-non-breaking field — → `doomgeneric_Create(3, {"doom","-iwad","doom1.wad"})`, pinning the exact name D_FindWADByName fopens. Tick: arm → doomgeneric_Tick → heartbeat +16 → 0 (unwound: 1). KeyIn: `ev = pressed \| doomkey<<8` (documented in §7). doomcc's already-landed crt0 machinery finds the three symbols → **header +20/+24/+28 nonzero for the first time** (verified in the emitted bytes and the map): the blob is a complete, callable artifact. jig: a **fakes TU** (no-op Create/Tick, `~port` merges only — doomcc links the real tree; the fake skips DG_Init, whose banner printf would spin the serial-less jig UART) makes the *real* entries runnable — `sj1` (double return 3 deep; `acc` pins restore-to-setjmp-time semantics) · `ext1` (the real exit from 4 deep: all three status mappings) · `in1` (the real Init: SHARED+28 → registration → `fopen("doom1.wad")` reads the WAD bytes back) · `tk1` (Tick twice: 0, 0, heartbeat 2) · `ki1` (KeyIn → ring → DG_GetKey round trip). 226 / 10678. undefined 11 → 9 — none port-layer. |
| **sweep** ✅ | the residue — ctype/errno, `__lsr` (var-count `>>`), integer-fps timedemo | ✅ **`fbfe211`** (2026-07-08) — `__ctype_b_loc`: the .i files expand `isspace()` &c into glibc's classification-table protocol (reached: m_argv's response-file parser runs inside Create); 384 u16 entries indexed from −128 (`isspace(EOF)` is legal), lazily built to the `_ISbit()` layout the .i enums carry — `ct1`/`ct2` diff the **whole flag word against genuine glibc** over both index sides (matched first run; can't drift). `__errno_location`: one never-set int, *correct* for the tree's one live read (M_FileExists's `errno == EISDIR` probe after a failed fopen reads 0 = "not a directory"; `er1`). `__lsr`: 11-instr Runtime helper (n=0 identity corner over one branch, else ROR + the `(1<<(32−n))−1` mask); the refusal became **4 lines of `gen_helper_call2`** — the s7 div-area protocol reused verbatim — plus the matching pre-scan arm (guarded to mirror gen_expr's routing exactly); `usrv` full-range vs gcc's native shift, `padrj` = PadRejectArray's byte-extract with `__udiv`/`__umod`/`__lsr` composing through one div area. `G_CheckDemoStatus`: the plan's "source-patch later," due — float fps → **integer tenths** (`%d.%d`); `-timedemo` *survives as exactly the 1d fps benchmark*; mechanically the first vendor patch (`spikes/cil/patches/0001`, applied idempotently by preprocess.sh — fresh clone and existing checkout converge). jig 231 / 10880. 1199/1240; undefined 9 → 5: three await flattening, `SetVariable`/`V_DrawMouseSpeedBox` stay self-loop traps **by design** (dead by locked decisions — if ever reached, the hang is loud). |
| **perf 4** ✅ | three-address flattening — the scratch-exhaustion retry; **1b is coverage-complete** | ✅ **`97397c2`** (2026-07-08) — the last three (`M_Responder` · `S_AdjustSoundParams` · `wipe_ScreenWipe`, all genuinely reachable in normal play) each had one statement holding more simultaneous scratches than 12 registers (deep chains + spilled-local loads + ROR masks + div-area staging, live at once). goblint-cil **dropped upstream CIL's Simplify**, so the deferred "CIL simplify pass" is ours to write — and rung 1 carries it: *a three-address temporary is just a local*, and locals past the homes already ride the spill slots. Fully internal to Fundec: `alloc_scratch` raises a dedicated `Scratch_exhausted`; `compile` catches it → `flatten_fundec` (~120 lines: `flat` returns an atom, hoisting a shallowed node into a fresh `makeTempVar` local; `shallow` keeps a statement's top operator — If conditions keep their relop, so the branch fusion survives; lvals keep their structure while embedded address math atomizes; call args become full atoms under claimed R0–R3; statement preludes via **in-place skind mutation**, so goto/case targets stay valid and a prelude lands under the original label — correctly: jumping there must re-evaluate the operands) → recompile once. Only exhausting functions pay the temp-heavy lowering; the other ~1200 keep their tighter code, and doomcc/jig change zero lines — the histogram bucket just evaporates. jig 234 / 11030 — `deep1`/`deep2`/`deep3`: right-nested chains over *memory* leaves (one held scratch per level, 14–16 deep) — unflattenable by any 12-register pool, so a green diff **proves** the retry ran, no instrumentation; deep2 composes with the div protocol, deep3 with the arg marshaller. **1202/1240 compiled, out-of-registers bucket gone, undefined 5 → 2 (the by-design traps): every reachable function in DOOM compiles.** Static instrs +2% (the three bodies); dynamic cost ≈ 0 by call rate. *Note for future sound support* (PWM, "Later"): `S_AdjustSoundParams` is both flattened *and* the hottest of the three — `S_UpdateSounds` re-adjusts every active channel per gametic (≤8 × 35 Hz ≈ 0.2% of the machine, naive) — fine even with real audio; if sound lands and profiling ever cares, the fix is an allocator-ladder rung, not a re-port. **The road to the first frame is now pure 1d infrastructure: the emulator's 24-bit himem patch (vendor), the sim harness preloading blob+WAD, the chunk splitter.** |

**Later** (each optional, independently landable): v2 viewer + task; Option A
`.rsc` envelope; PS/2 Pmod keys; mouse burst-turn; PWM audio; **allocator
upgrades as the perf pass** (linear-scan and beyond) behind the frozen ABI —
the 1a asm drawers survive every codegen change.

The backend (1b) is **done — coverage-complete as of `97397c2`
(2026-07-08)**: every reachable function in DOOM compiles (1202/1240; the
38 refusals are all unreachable-or-replaced code, and the 2 remaining
undefined symbols are by-design traps). A C backend for the world's
cleanest 32-bit ISA proved exactly the gentle introduction predicted —
built in ~30 slices over three days, each trusted only once the
differential jig (234 samples / 11 030 cases) matched gcc. With the 1c host
reference build landed (`14f92c7` — the anchor of the golden-frame and
desync oracles) and the emulator's himem widening landed (upstream
`f52d904`, pinned at `f59df92`: 16 MiB default, kernel worldview and fb
window untouched — the emulator-side mirror of 2a; `test_blob` now runs the
blob envelope + crt0 excursion at the real `BLOB_BASE 0x100000` /
`STACK_TOP 0x300000`), and the WAD chunk splitter landed (`lib/wad.ml` +
`bin/wadsplit.ml`: §3's ≤3 MiB byte-range chunks under the PO file cap
3 210 912 = 64 direct + 12×256 indirect KB − the 352 B header; name
sequence `doom1.wad.0`, `.1`, … is the manifest the stub walks;
`test_wadsplit` pins the invariants and the real WAD splits into 2 chunks,
reassembly md5-verified against the shareware pin), **the first frame is on
the screen**: `bin/doomrun.ml` (2026-07-08) plays the stub on the emulator
at the real ABI addresses, and the blob — every byte of it compiled by our
backend or hand-assembled through the eDSL — boots DOOM, renders TITLEPIC,
and plays the E1M1 attract demo in dithered 1-bit (three first-contact
bugs found and gated: the §8 WAD-window widening, the `materialize_addr`
register clobber, vsnprintf integer precision). What remains of 1d is the
oracle instrumentation (golden ≡ host-dither comparison, gametic desync
checksum vs the host run), the Cyclesim and hardware legs — and then
performance
work chosen by measurement (`-timedemo` survived the float ban precisely to
be that instrument), not by guess: the §4 allocator ladder (local →
linear-scan) and the 1a hand-rolled hot loops are the two levers, and 1d's
numbers pick between them.

Cross-cutting oracle: the host build of the same amalgamated TU (ILP32-clean
via stdint) is both the debugger and the golden generator — and the IWAD's
built-in demos are deterministic, so a demo that plays without desync
(checksummed gametic state vs the host run) certifies DIV semantics,
fixed-point, and alignment in one shot. Cheap insurance against
silently-wrong arithmetic surfacing as "monsters walk through walls" three
phases later.

And the verification triangle is already in the barn: the vendored OCaml
emulator (`vendor/oberon-risc-emu-ocaml`, lockstep-tested against the core
since Phase 4) got its 24-bit map patch — the same widening 2a does in
silicon (upstream `f52d904`, 2026-07-08) — and loads blobs in himem at the
ABI addresses today. That makes it track 1's
everyday target (full DOOM at near-realtime, vs 10 s/frame in Cyclesim),
with Cyclesim as the cycle-accurate check and silicon as the truth. Any two
disagreeing localizes the bug: emulator ≠ Cyclesim is a machine or model
bug; both ≠ host reference is toolchain or port.

## 8. Open questions

- Exact himem layout: blob load addr, stack, zone size, WAD placement, back
  buffer — one page of constants, frozen at 3a (it's a seam artifact;
  everything downstream bakes it in).
- ~~doomgeneric `CMAP256` + our little-endian packing — confirm buffer format
  at 1c~~ — **confirmed and implemented (port.2/port.3)**: `-DCMAP256`
  `-DDOOMGENERIC_RESX/Y=320x200` at preprocess makes `DG_ScreenBuffer` the
  raw 320×200 index buffer (`fb_scaling = 1`, I_FinishUpdate a plain copy);
  the dither-blit reads it and `colors[]` as BGRA bytes (the byte-aligned
  `:8` LE layout, pinned against gcc by the jig's `bf1`). ~~Confirm
  `I_SetPalette` is surfaced under `CMAP256`~~ — answered by the census:
  under `CMAP256`, `extern struct color colors[256]` is exported precisely
  for the platform layer, `I_SetPalette` refills it on every palette switch
  (gamma pre-applied via `gammatable`), so the LUT dither (§5, simplified
  to one-LUT-on-`palette_changed`) reads it with zero doomgeneric patches.

## 9. Locked — the all-OCaml toolchain (CIL route)

The hardware is OCaml; the toolchain is too. Formerly spike-gated; **the
gate ran green on both machine models** — full evidence in
`spikes/cil/RESULTS.md`. What the spike proved (goblint-cil 2.1.0, the
real doomgeneric tree): **80/80** port-relevant TUs parse (`-std=gnu99`
pin; gcc 15's C23 default was the only blocker), `Mergecil.merge` clean
with exactly **10** DOOM-real static renames (the PureDOOM rename map,
automated), **12 080** CIL instrs across 1 184 functions — the measured
backend workload — identical stats under the RISC5 ILP32 machdep (char
unsigned, little-endian), and the merged TU recompiles under host gcc;
`-m32` sizes: .text 404 K + .data 62 K + .bss 245 K ≈ 712 K, comfortably
inside the 1.75 MB blob cap.

What CIL is: a C front-end *as an OCaml library* (maintained, on opam;
C99/C11 + GNU extensions) — expressions arrive guaranteed
side-effect-free (assignments/calls/`++` hoisted into explicit instrs
over typed temporaries — most of the way to three-address code), types
fully resolved, CFG included; `Mergecil.merge` is the single-TU
amalgamation. CIL has **no codegen** (its only backend pretty-prints C),
so the route is: CIL front-end + our backend in OCaml.

Why it fits this repo: the backend extends machinery already in the grain
here — a typed ISA next to the emulator, the lockstep-proven oracle, the
differential-qcheck house style. The shared `risc5_isa` (a fresh stock-OCaml
module, host repo) gives one `encode`/`decode` to core tests, emulator,
linker, and compiler — encoding *cannot drift* — and verification reaches
inside the compiler (random C snippet → our backend in the emulator vs host
gcc, diffed) instead of stopping at the blob. 3b's assembler is an
instr-level linker over that type; the 1a hot functions are an OCaml eDSL
emitting instrs directly (text assembly deferred, §4).

The honest cost: we own codegen quality and correctness. Naive
all-in-memory codegen lands ≈2× optimal even with the asm hot half
(0.5·1 + 0.5·3); reaching the classic compiler+asm shape (~1.3×) needs at
least local register allocation, ideally linear-scan — known-shaped work,
incrementally landable behind a correct-but-slow first cut. Guardrails: CompCert stays
out (retargeting = Coq semantics + re-proofs for a new ISA; and Wirth
RISC5 ≠ RISC-V — nothing to borrow), and the host reference build stays
plain gcc on original sources — CIL runs only on the target path, so a
CIL front-end bug can't corrupt both sides of the diff. If the backend
stalls outright, the escape hatch is §4's: retarget lcc/vbcc onto the
frozen seam — the ABI, track 2, and the himem plan were
compiler-agnostic on purpose and don't move.

---

*Host repo: [oberon-risc-hardcaml](https://github.com/zxygentoo/oberon-risc-hardcaml) (Hardcaml design, board layer,
sim/verification harnesses). This repo: the DOOM arc — toolchain, runtime,
stub, blob. Cross-repo: the machine work (2a) and the shared `risc5_isa`
module both land in the host repo — stock OCaml, upstream of both the
compiler and the emulator. Pointing the emulator's own `single_step` at
`risc5_isa` — a later, independent sub-project — **landed 2026-07-06**
(accessor-first API proved zero-cost, ABI §6; vendored at `e36fcf0`, host
`develop` green); the DOOM arc didn't wait on it.*
