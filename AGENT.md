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
| **2c** | stub loader: blob file + WAD chunks → himem (host-side chunk splitter included); header parse; `.bss` zero | loads a crafted image; himem contents verified |

**Milestone — hello blob** (closes tracks 2+3): a hand-assembled blob through
the full path — stub loads it, stack switches to himem, R12–R15 saved, writes
framebuffer + UART, restores, returns clean — on the emulator, Cyclesim,
*and* silicon. Its natural extension, the **test-jig blob** (run vectors,
dump results), becomes the standing harness track 1 plugs into. After this milestone, every failure
is content, not infrastructure.

**Track 1 — the content** (the long pole, now ringed by a proven harness)

| | Deliverable | Verify |
|---|---|---|
| **1a** | hand-rolled hot functions: `FixedMul`/`FixedDiv`, DIV/MOD fixup helpers, `R_DrawColumn`/`R_DrawSpan`, `mem*` | each runs in the jig in Cyclesim vs host reference — before the backend exists |
| **1b** ◐ | the OCaml backend: CIL (gnu99 pin, RISC5 32-bit machdep, `Mergecil.merge`) → shared `risc5_isa` instrs → blob; ABI. Built on **two axes** — feature coverage (the *slice ladder* below) and allocation quality (naive → local → linear-scan, the *later* perf pass, §4) | compiled jig blobs vs host: division across all four sign combos (`/` and `%`), call-heavy torture functions; **random-C-snippet differential** — our backend in the emulator vs host gcc; every increment through the same jig |
| **1c** | `Mergecil` single TU (spike-proven, `spikes/cil/`) + mini-libc + C ports of the 2b prototypes + **host reference build** (plain gcc on original sources — CIL stays target-path-only) | host build plays E1M1; pieces unit-tested in the jig |
| **1d** | first frame of E1M1 **in simulation** — harness preloads blob+WAD straight into the PSRAM model; pixel-exact framebuffer dumps via the visual-golden harness, a bring-up luxury no DOOM port ever had. (0.39 M cyc/s ≈ 10 s/frame is *steady-state*; `D_DoomMain` init is hundreds of M cycles ≈ tens of sim-minutes — don't debug a "hang" that is `R_InitTextures`.) Then v1 stub on hardware | sim framebuffer golden ≡ host-reference frame (same dither code, bit-identical); demo desync check; on-hardware E1M1 |

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
| **s4** ◐ | calls — the ABI frame (§3) over the new **`Linker`** (`resolve` lifted from one function to a whole program, ABI §6). The slice where the register split goes *live*: a `BL` clobbers R0–R5 + H + flags, so values live across a call move to callee-saved R6–R11 and a callee saves exactly the callee-saved regs it writes (+ LNK if non-leaf). Five sub-slices: **s4.1a** the callee *shape*, no calls — prologue/epilogue save/restore used R6–R11, return via `B LNK` (`To_reg 15`); `Runner` gains a stack (SP) + an LNK sentinel; Fundec still returns `instr list` · **s4.1b** the call + `Linker` — arg marshalling (evaluate each arg → `STW` to the §3 home area → `LDW` R0–R3, so evaluation and register placement decouple: no parallel-move puzzle), `BL` a named callee, result in R0; non-leaf homes migrate to R6–R11 · **s4.2** stack args + FP (args 5+ at `FP+16..`) · **s4.3** address-taken locals → FP-relative stack slots (`vaddrof`; `&local` deferred from s3) · **s4.4** aggregates by value (struct args stack-copied, struct return via hidden pointer) | **s4.1a** ◐ next — existing jig green with real frames + a forced high-register-pressure sample exercising the save path; s4.1b on — multi-function (caller+callee, recursion) diffed vs gcc. Coverage honesty: CIL hoists every call/subexpr into a local, so the 547 *split* — many move to "too many regs (needs spilling)", the §4 perf pass, not s4 |
| **s5** | the odds — `!` / compare as a 0/1 value, unsigned ordered compares (incl. pointer `<`/`>`, which CIL lowers to unsigned — signed is exact in our 24-bit address space, so this is where pointer-walk `while (q < end)` unblocks), `switch`, `continue` (CIL → goto) | pending |

**Later** (each optional, independently landable): v2 viewer + task; Option A
`.rsc` envelope; PS/2 Pmod keys; mouse burst-turn; PWM audio; **allocator
upgrades as the perf pass** (linear-scan and beyond) behind the frozen ABI —
the 1a asm drawers survive every codegen change.

The backend (1b) is still the biggest single piece — a C backend for the
world's cleanest 32-bit ISA remains the gentlest possible introduction to
compiler backends — but it's now the *last* thing standing instead of the
first long pole: by the time it emits its first function, the assembler,
loader, sim path and host oracle are all battle-tested, so any failure is
the backend's fault and nothing else's.

Cross-cutting oracle: the host build of the same amalgamated TU (ILP32-clean
via stdint) is both the debugger and the golden generator — and the IWAD's
built-in demos are deterministic, so a demo that plays without desync
(checksummed gametic state vs the host run) certifies DIV semantics,
fixed-point, and alignment in one shot. Cheap insurance against
silently-wrong arithmetic surfacing as "monsters walk through walls" three
phases later.

And the verification triangle is already in the barn: the vendored OCaml
emulator (`vendor/oberon-risc-emu-ocaml`, lockstep-tested against the core
since Phase 4) needs only the 24-bit map patch — an hour in OCaml, the same
widening 2a does in silicon — to load blobs. That makes it track 1's
everyday target (full DOOM at near-realtime, vs 10 s/frame in Cyclesim),
with Cyclesim as the cycle-accurate check and silicon as the truth. Any two
disagreeing localizes the bug: emulator ≠ Cyclesim is a machine or model
bug; both ≠ host reference is toolchain or port.

## 8. Open questions

- Exact himem layout: blob load addr, stack, zone size, WAD placement, back
  buffer — one page of constants, frozen at 3a (it's a seam artifact;
  everything downstream bakes it in).
- doomgeneric `CMAP256` + our little-endian packing — confirm buffer format at
  1c (RISC5 is little-endian, matches WAD; watch packed-struct alignment,
  though doomgeneric already carries fixes from ARM ports). ~~Confirm
  `I_SetPalette` is surfaced under `CMAP256`~~ — answered by the census:
  under `CMAP256`, `extern struct color colors[256]` is exported precisely
  for the platform layer, `I_SetPalette` refills it on every palette switch
  (gamma pre-applied via `gammatable`), so the 14-LUT dither (§5) reads it
  with zero doomgeneric patches.

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
