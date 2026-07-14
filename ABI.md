# ABI.md — the 3a spec (calling convention · asm · blob format · himem layout)

**Status: FROZEN v1 (2026-07-05) — changes require a `version` bump (§10).**

Consumers: the OCaml backend (1b), the 1a eDSL, the `risc5_isa` module +
instr-level linker (3b; `risc5_isa` lives in the host repo, stock OCaml),
stub loader (2c), sim harness (1d), Oberon prototypes (2b). Every constant
and convention below is load-bearing for all of them; change nothing here
after freeze without bumping the header version.

## 1. Machine assumptions

- RISC5 @ 60 MHz, little-endian, flat 24-bit byte addresses (16 MiB).
- **No interrupts enabled, no traps, no MMU.** (Confirm-in-sim item C1.)
- `LDB` zero-extends — there is no sign-extending byte load ⇒ `char` is
  **unsigned** (free choice; the other costs 2 instructions per load).
- Shifts are `LSL`/`ASR`/`ROR` — **no logical shift right**; unsigned `>>`
  compiles to `ROR` + `AND` mask.
- `MUL` leaves the high 32 bits in `H`; `DIV` leaves the remainder in `H`.
- Hardware `DIV` precondition: **divisor ∈ [1, 2³¹−1]**, signed and unsigned
  both (`divider.ml` qcheck). Everything outside goes through helpers (§5).
- Mem-op offsets are 20-bit signed (±512 KB reach from a base register);
  branch offsets 24-bit signed words (whole space reachable, no long-branch
  pseudo needed).
- Conditions: derive from an explicit compare or the defining ALU op; do
  **not** rely on flag side-effects of loads (confirm-in-sim item C2).

## 2. Registers

| Reg | Role | Saved by |
|---|---|---|
| R0 | arg 1 / return value / temp | caller |
| R1–R3 | args 2–4 / temps | caller |
| R4–R5 | temps | caller |
| R6–R11 | register variables (callee-saved regvars) | **callee** |
| R12 | **FP** frame pointer | callee |
| R13 | **DB** data base (set once by crt0; never changed) | reserved |
| R14 | **SP** stack pointer, full-descending, 4-aligned | — |
| R15 | **LNK** (hardware: `BL` writes it) | caller (non-leaf saves it) |
| H | MUL high / DIV remainder | clobbered by MUL/DIV and any call |
| flags | N Z C V | never live across a call |

Split rationale (frozen 6/6): six caller-saved (R0–R5) comfortably covers a
naive backend's expression scratch — real C rarely needs >4 simultaneously
live temps — so the other six go callee-saved, for values live across calls.
This maximizes the callee-saved side, which is the one that matters: it is
pay-per-use (unused ones cost nothing) *and* the side that can't be widened
later without breaking hand-asm that hard-codes what it may clobber. So if a
future measurement disagrees, the safe error is on this side. Hand-rolled
leaves use all of R0–R11 freely, amortizing any callee-saved saves over
their loops.

## 3. Calling convention (o32-shaped — simple, proven, varargs for free)

- Args 1–4 in R0–R3; args 5+ on the stack. The caller **always** reserves a
  16-byte *home area* at `SP+0..15` (slots for R0–R3); arg 5 lives at
  `SP+16`, arg 6 at `SP+20`, … at the instant of `BL`.
- Return value in R0. No 64-bit types exist (§4), so no register pairs.
- **Aggregates** are never in registers: struct args are copied to the
  stack; struct returns go via a hidden pointer passed as a synthetic first
  arg in R0 (the classic hidden-pointer rewrite).
- **Varargs**: callee stores R0–R3 into its home area on entry; `va_list` is
  a `char*` walking upward. (`printf`/`I_Error`/`sprintf` are the only
  consumers.)
- Frame idiom (non-leaf):

```
        SUB  SP, SP, frame       ; frame = saves + locals + outgoing area
        STW  LNK, SP, frame-4
        STW  FP,  SP, frame-8
        ADD  FP, SP, frame       ; FP = entry SP: incoming args at FP+0…
        STW  R11, SP, frame-12   ; …callee-saved regs, as used
        ...
        LDW  R11, SP, frame-12
        LDW  FP,  SP, frame-8
        LDW  LNK, SP, frame-4
        ADD  SP, SP, frame
        B    LNK
```

- Leaf functions may skip FP, LNK save, and the frame entirely.
- Oberon compatibility: ORG also evaluates the first parameters into R0… —
  for the ≤3-arg blob entries the conventions coincide at the boundary; the
  crt0 thunks (§7) own everything else.

## 4. C type metrics

| | |
|---|---|
| char | 8-bit **unsigned** (chocolate-doom lineage is already clean here) |
| short | 16-bit |
| int, long, pointers | 32-bit |
| long long | **does not exist** — census-verified (the §9 spike census, AGENT.md; enforced by lib/check.ml): `FixedMul`/`FixedDiv` are the tree's *only* 64-bit sites, and both are 1a asm |
| float, double | **banned in the blob v1** — census-verified strays are 6 cold functions (m_config float vars, am_map zoom, mouse-speed box (dead — no mouse), timedemo fps print), excised/pinned at 1c; RISC5 single-precision FPU exists if ever needed |
| alignment | natural, max 4; stack and structs word-aligned |
| packed | **no packed attribute** — `PACKEDATTR` defined empty; every WAD-facing struct gets a `sizeof` assert in the host reference build |
| bitfields | **banned outright** — census-verified (the §9 spike census, AGENT.md; enforced by lib/check.ml): sole user is `struct color` (i_video.h, not WAD-facing), patched to plain `uint8_t` fields at 1c; on-disk structs confirmed clean (integer fields + mask macros); backend never implements a bitfield ABI |

## 5. Runtime helpers and intrinsics

Helpers (hand-rolled, 1a) — standard ABI calls, clobber caller-saved only:

| Symbol | Contract |
|---|---|
| `__div`, `__mod` | signed truncating `/` `%`; wrap hardware DIV (negate-before / fix-after); full sign coverage |
| `__udiv`, `__umod` | unsigned; fast path hardware DIV, slow path for divisor ≥ 2³¹ (quotient is 0 or 1) |
| `FixedDiv` | `(a<<16)/b`, 48/32 software long division, ~200–300 cycles |
| `memcpy`, `memset`, `memmove` | word-loop cores |

The backend maps C `/` and `%` to these calls; it never emits a bare `DIV`.

**Intrinsics** (an `instr list → instr list` pass, §6) — registry frozen
at: `{ FixedMul }`. A `FixedMul` call expands inline (≈6 instructions:
`MUL`, `MOV'` from H, `LSL`/`ROR`/`AND`/`IOR`), result in R0, clobbers
R0–R1 + H + flags — within the ABI's notion of a call, so callers can't
tell (except by being fast).

## 6. The assembler/linker layer (over risc5_isa)

The canonical representation is `risc5_isa.instr` — a **host-repo,
stock-OCaml** module: the instr ADT + `encode`/`decode` + inlinable field
accessors, the single definition of the RISC5 encoding. It's shared by the
compiler backend, this layer, the core tests, and — a later sub-project —
the emulator's own decode (the accessor layer is shaped so `single_step`
adopts it at ~zero cost — **spike-proven** on the vendored emulator: every
`[@inline]` accessor compiles to zero calls, bit-exact under both stock
non-flambda and flambda2; the sole nuance is that matching the `kind` *variant*
on the hot path costs a few % under non-flambda — free under flambda2 — so a
hot decoder can branch on `p`/`q` directly, though the emulator ships
`match kind` anyway, the cost being immaterial for a dev target). The backend
emits `instr` lists directly;
hand-written 1a code is an OCaml eDSL constructing the same `instr` values.
Nothing round-trips through text. The concrete API — accessors, the `instr`
ADT, `encode`/`decode`, and the invariants — is defined in
[`risc5_isa.mli`](vendor/oberon-risc-hardcaml/vendor/oberon-risc-emu-ocaml/lib/risc5_isa.mli) (landed in the
vendored emulator; the standalone host-repo module is the 3b hoist).

So the "assembler" is not a parser but an **instr-level linker** — a small
pipeline of `instr list` passes:

- **Label/branch resolution** — symbolic labels (a DOOM-repo layer *above*
  risc5_isa; `risc5_isa.instr` itself carries resolved offsets only) become
  concrete PC-relative / DB-relative offsets; forward refs are a two-pass.
- **Pseudo / intrinsic expansion** — `LEA Rd, label` → `MOV'`+`IOR` (2
  words); the `FixedMul` intrinsic (§5) → its ≈6-instr inline.
- **Addressing** — register aliases `FP DB SP LNK` (§2); global data is
  DB-relative; an absolute address is placed as a data word.
- **Section layout** — code / data / bss flattened in order; bss reserves
  without emitting; the flat image links at a fixed himem address (§8), no
  relocation.
- **Header + map** — auto-emit the §7 header (lengths, entry offsets from
  the crt0 entries, checksum); dump a symbol map. `[@@deriving show]` on
  `instr` gives free listings — the debugging currency.

**Deferred, both directions (demand-driven):** a text *parser* (text →
instr) and a canonical-mnemonic *disassembler* (instr → text). Neither is
on a critical path — backend and eDSL both produce `instr`, deriving-show
covers reading — so each is a leaf, addable later at zero cost to the rest.
Build one the first time it itches (most likely a hot loop you'd rather
hand-edit as `.s`). The eventual text syntax, if built: one instr/line,
`;` comments, `name:` / `.Lname` labels, mnemonics with `'` for u-variants,
`@label` / `.word` / `.code` / `.data` / `.bss`, no macros, no expression
grammar.

Worked leaf (no frame), shown in that deferred text view — the near-term
eDSL constructs the identical `instr` list:

```
; void bzero8(char *p, int n)   ; R0 = p, R1 = n
bzero8: MOV  R2, 0
.Lloop: STB  R2, R0, 0
        ADD  R0, R0, 1
        SUB  R1, R1, 1
        BNE  .Lloop
        B    LNK
```

## 7. Blob header + boundary protocol (v1)

Fixed 64-byte header at `BLOB_BASE`; additive growth allowed within 64 B,
anything else bumps `version`.

| Offset | Field |
|---|---|
| +0 | magic `0x4D4F4F44` (`"DOOM"` little-endian) |
| +4 | version = 1 |
| +8 | image length (header+code+data, bytes) |
| +12 | bss start (absolute) |
| +16 | bss length (stub zeroes this range) |
| +20 | entry: Init offset from BLOB_BASE |
| +24 | entry: Tick offset |
| +28 | entry: KeyIn offset |
| +32 | checksum: additive u32 over image words after the header |
| +36…+63 | reserved, zero |

Entries are **crt0 thunks** that own the world switch:

```
save R6–R15 → save area in blob data     ; Oberon's world, parked
SP  = STACK_TOP ; SUB SP, SP, 16         ; C stack + initial home area
DB  = LEA DB, __data_base
BL   <C entry>                            ; args already in R0/R1 (§3)
restore R6–R15
B    LNK                                  ; back to the stub
```

Signatures: `Init(wad_addr, cfg_addr) → 0 | error code`;
`Tick() → 0 continue | 1 quit`; `KeyIn(ev)` (enqueues; v1 blob also polls
UART itself, §6 of AGENT.md) — `ev = pressed | doomkey << 8`, the §8
ring/wire byte order. `exit()`/`I_Error` set status in the shared
page and return through the thunk — never halt (realized as a
setjmp-shaped unwind: each entry arms a jmp_buf of the callee-saved state
R6–R12/SP/LNK; `exit` restores it and the entry returns normally).
In v1, `cfg_addr` is the §8 SHARED page (the blob also reaches it through
its baked link-time binding).

## 8. Himem layout v1 (the constants page)

Oberon owns `[0, 1 MB)` — stock kernel, 1 MB worldview, never touches
himem. Top of the 16 MiB space (`≥ 0xE01000`) is left untouched (ROM/MMIO
decode territory + margin).

| Base | End | Size | Contents |
|---|---|---|---|
| `0x100000` | `0x2C0000` | 1.75 MB | **BLOB**: header, code, data, .bss (cap) |
| `0x2C0000` | `0x300000` | 256 KB | **C stack**, grows down from `STACK_TOP = 0x300000` |
| `0x300000` | `0x301000` | 4 KB | **SHARED page**: cfg in, status out, key ring |
| `0x301000` | `0x310000` | 60 KB | spare (`0x30E000`–`0x310000`: the **Halftone table window**, §11) |
| `0x310000` | `0x320000` | 64 KB | **Halftone pixel window** (§11; né "back buffer" — pixels + tone LUT + registers; software-dither builds leave it untouched) |
| `0x320000` | `0x400000` | 896 KB | spare (wipe buffers, LUTs, growth) |
| `0x400000` | `0xA00000` | 6 MB | **zone** (DOOM's Z_Malloc block) |
| `0xA00000` | `0xE01000` | 4 MB + 4 KB | **WAD** (chunks concatenated by stub; the real shareware WAD is 4 196 020 B — 1 716 past 4 MiB, so the window carries one extra page) |

No hardware guard pages exist; the blob/stack gap is convention. A stack
that grows past `0x2C0000` corrupts .bss silently — the jig's stack-depth
test (BSP recursion worst case) is the insurance.

SHARED page (v1 fields; rest reserved):
`+0` magic · `+4` version · `+8` flags (reserved) · `+12` blob status
(0 running, 1 quit, negative = I_Error code) · `+16` frame counter
(heartbeat, incremented by `Tick`) · `+20` key ring head · `+24` tail ·
`+28` WAD length in bytes (stub writes before `Init`) · `+32…` ring of
2-byte events (make/break, code), 256 entries · `+1024…` the **command
tail**: NUL-terminated text, ≤ 3 KB — the loader writes the raw tail
verbatim before `Init` (a zeroed page is the empty tail; no parsing on the
loader side — an Oberon stub byte-copies `Oberon.Par`'s text up to `~`, the
harness copies its `-args` string). `Init` prepends the baked
`doom -iwad doom1.wad` and tokenizes on blanks **in place** (writing NULs),
so the region belongs to the blob after `Init` — `myargv` points into it.

Key-ring discipline (v1; a §10 non-breaking clarification of the fields
above): head and tail are free-running u32 counters, masked at use
(index = counter & 255) — empty is `head = tail`, full is
`head − tail = 256`, both exact across the u32 rollover. The producer
(stub `KeyIn` / a UART poll) writes the 2-byte event at
`+32 + 2·(head & 255)`, *then* increments head; the consumer (the blob's
`DG_GetKey`) reads at `+32 + 2·(tail & 255)` when `tail ≠ head`, then
increments tail. A full ring drops the event, producer-side. Event bytes:
byte 0 = pressed (1 make, 0 break), byte 1 = doomkey code (`doomkeys.h`) —
the sender owns all translation; the blob never sees a scancode. The stub
zeroes the SHARED page (head = tail = 0) before writing magic/version and
calling `Init`.

SHARED `+544` (a §10-non-breaking reserved-field addition, 2026-07-14): the
**presentation flags**, loader-written before `Init`. Bit 0 = the Halftone
hardware is present (zero — every pre-Halftone loader/harness — is the
software dither, bit-identically unchanged). Bit 1 = viewer presentation:
the *stub* owns mode + geometry; the blob keeps thresholds + LUT + frame
copy (§11).

## 9. Confirm-in-sim checklist (becomes the first jig vectors)

- **C1** — interrupts genuinely never fire (else R12/H/flags rules change).
- **C2** — whether loads set N/Z (we forbid relying on it either way).
- **C3** — `DIV'` (unsigned) with divisor ≥ 2³¹: confirmed-unsupported;
  helper slow path covers it.
- **C4** — `MUL'` (unsigned) H semantics vs the signed case.
- **C5** — `MOV'` variants: H read (v=0) vs flags read (v=1) encodings.

## 10. Freeze protocol

**Frozen as v1 on 2026-07-05.** The register map, calling convention, type
metrics, header offsets 0–35, and the layout table are **locked** — changes
mean `version = 2` and a conscious migration of every consumer. Additions to
reserved header/SHARED fields, new linker passes, and the eventual text-view
syntax are non-breaking. The §9 confirm-in-sim items (C1–C5) are documented
assumptions the freeze rests on; if one falsifies at bring-up, that is itself
a `version = 2` event.

Amendments within v1 (all additive; blob header untouched): the WAD window
end `0xE00000 → 0xE01000` (2026-07-08, first contact with the real shareware
WAD); the key-ring discipline and SHARED `+28`/command-tail clarifications
(§8); SHARED `+544` presentation flags + **§11**, the Halftone display seam —
promoted 2026-07-15 from the draft `halftone-seam.md` after the mode shipped
(board-proven, merged in both repos; the draft doc is retired).

## 11. The Halftone display seam (shipped 2026-07-14; v1-additive)

The generalized indexed/grayscale display mode — hardware: the host repo's
`Halftone` (`board/nexys-4/halftone.{ml,mli}`, its AGENT.md §5 row 11);
Oberon face: `Halftone.Mod` (shipped with the hardware, `board/nexys-4/Mod`);
DOOM's raw-MMIO client: `libc/dither.c` + `libc/doom_oberon.c`. **The
hardware keeps only mechanism; every policy — tone, thresholds, geometry —
is client-uploaded at runtime.** Power-up state is all-zero: a zero-sized
rect claims nothing, so mode-off elaboration is display-identical to a board
without the module.

### The pixel window (64 KiB at `HT_BASE = 0x310000`)

The §8 row, repurposed. The board shadows every PSRAM-bound store in the
window (write-through, the Framebuf/cache tap); PSRAM keeps the truth, CPU
loads are untouched.

| byte offset | contents |
|---|---|
| `+0 .. +63999` | pixel bytes — **meaning is client-defined**: the row map names each displayed row's byte offset, so 320×200 row-major, strided images, or a double-buffered pair are all just row maps. Clients render **complete frames** here (the 2026-07-10 board lesson: the raster must never watch a renderer mid-sweep) |
| `+64000 .. +64255` | tone LUT: index = pixel byte, value = 8-bit gray |
| `+64256 ..` | the register block, below |

### The register block (`HT_CTL = HT_BASE + 64256`; word stores, write-only)

| reg | offset | width | semantics |
|---|---|---|---|
| `CTL` | +0 | bit 0 | mode. **Immediate** (not latched) — `exit()`'s instant desktop restore depends on it |
| `WIN_X` | +4 | 11 | rect left, panel px, **multiple of 32** (the claim mux selects whole fb words) |
| `WIN_Y` | +8 | 10 | rect top, panel px |
| `WIN_W` | +12 | 11 | rect width, **multiple of 32**, `X+W ≤ 1024` |
| `WIN_H` | +16 | 10 | rect height, `Y+H ≤ 768` |
| `XNUM` | +20 | 12 | horizontal scale numerator; **`XNUM ≥ XDEN ≥ 1`** (upscale or 1:1 only) |
| `XDEN` | +24 | 12 | horizontal scale denominator |
| `XOFF` | +28 | 16 | starting source byte column (horizontal pan = one write) |

Geometry registers are **shadowed**: stores hit the shadow; hardware copies
shadow → active once per frame at vblank entry, so a mid-frame `Open` never
tears. The table RAMs (below) are live — rewrite during vblank
(`Halftone.Sync`; the blanking window is ~600 µs) or with the mode off.

### The table window (8 KiB at `HT_THR = 0x30E000`, carved from §8's spare)

| byte offset | contents |
|---|---|
| `+0 .. +4095` | **threshold map, verbatim**: 64×64 bytes row-major, values 1..254 (DOOM stores `__dg_bn64` as-is) |
| `+4096 .. +7167` | **row map**: 768 words, entry `y` = rect-relative output row — bits `[15:0]` = `row_base` (source row's byte offset in the pixel window), bits `[21:16]` = `thr_row` (threshold row). **Word stores only** |
| `+7168 .. +8191` | reserved |

The row map is the load-bearing generalization: any vertical scale or
dealing — Bresenham, 1:1, double-buffer flips, interleave — is a software
loop over ≤768 words; no multiplier, divider, or vertical DDA exists in
hardware. DOOM uploads the exact out2 dealing, keeping the hardware
**bit-identical to `__dg_dither_fs`** and every golden.

### The decision function and the horizontal DDA (exact)

Per output pixel of a claimed word: `bit = (lut[pix[row_base + sx]] >
thr[thr_row][ox & 63])`, `ox` = panel x, bit 0 of a word = leftmost. `sx`
advances by the output-driven DDA, frozen as:

```
row start:         sx := XOFF;  acc := XDEN
per output pixel:  emit(sx);  acc := acc + XDEN;
                   if acc > XNUM { acc := acc − XNUM; sx := sx + 1 }
```

At `16/5` this deals source widths 3,3,3,3,4 — exactly the software kernel's
slot tables (host-repo test-pinned). At `XNUM = XDEN` it is the identity.
DDA state carries across a rect row (video requests raster-order).

### The overlay rect, frame sync, and mode discipline

Per video request: `claim = mode ∧ (y_req < 768) ∧ (y_req, col) ∈ rect`,
latched at request-accept; the board muxes `viddata/vid_ack/vidpar` from
`Halftone` when the completing request was claimed, from `Framebuf`
otherwise. Inside the rect the mono framebuffer (including the Oberon mouse
pointer) is simply not displayed — a client wanting a cursor draws its own.

Status register (MMIO `0xFFFFE8`, slot 10, read-only): bit 0 = vblank,
bits `[15:8]` = frame counter (increments at vblank entry — the edge that
latches the geometry shadows). Vblank is detected as a video **request gap**
(video issues no fetches during blanking; a saturating watchdog fires ~68 µs
in). The machine's first readable frame clock.

Mode discipline (v1, blob-owned — §5 blob-talks-MMIO): upload thresholds +
row map + LUT + geometry, then **mode on at the first `DG_DrawFrame`**
(never at Init), **off in `exit()`** (instant desktop restore — the mono
framebuffer was never written). Mode-on over zeroed tables scans all-zero
thresholds: every non-black pixel white; upload first. Under SHARED `+544`
bit 1 (§8) the stub owns mode + geometry instead: `DOOM.Run -win`'s viewer
lifecycle re-`Open`s the largest 4:3 rect per ModifyMsg, and quit/suspend
drop the mode.

Arbitration (2026-07-15, `Halftone.Mod` policy — the hardware stays pure
mechanism): the rect is **single-owner at consumer lifetime** — `Claim` takes
it for as long as the consumer lives (a viewer from open to close, or one
command), `Release` frees it (parameterless: doubles as the recovery command
for a claim wedged by a dead client). While a claim is live a second `Claim`
returns FALSE; the client reports ("close its owner first") and the user
exits the current consumer before opening the next — `DOOM.Run -win` refuses
up front, before Load+Init; `Mandel.Open` refuses before opening its viewer.
Inside a claim the window is the owner's through suspend and resize alike:
`Open` (re)shapes the rect (it refuses outside any claim, so a
forgot-to-Claim client fails loudly — but it cannot tell owners apart:
cross-client exclusion is `Claim`'s alone), `Off` blanks the picture while
covered, and the tables never change hands — which is what makes the blob's
one-time threshold upload safe for the whole session: a live DOOM window can
never see foreign tables. The seize path stays outside the claim by
construction — the seized loop freezes every claimant, and the exit restore
broadcast lets a suspended claimant re-shape and re-upload (Mandel re-sends
its tables at every mode-on, so it self-heals).
