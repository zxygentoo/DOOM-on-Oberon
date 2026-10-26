# ABI.md — the blob's ABI (calling convention · linker · blob format · himem layout)

**Status: FROZEN v1 (2026-07-05) — changes require a `version` bump (§10).** This
is the v1-final text, corrected against the implementation at release (§10): no
field or offset changed, and no code — it always did what this text now says.

Consumers: the compiler (`lib/` — codegen, the instr-level linker, the
hand-written runtime helpers and drawers, the crt0 thunks), the loader
(`patch/oberon/DOOM.Mod`) and its harness doubles (`bin/run_blob.ml`,
`bin/run_dsk.ml`, `bin/emit_rom.ml` for the Cyclesim model), and the jig. The §8
constants page is also code, `lib/abi_constants.ml`; this file is the
cross-language authority.

## 1. Machine assumptions

- RISC5, little-endian, flat 24-bit byte addresses (16 MiB). (The board clocks it
  at 64 MHz; nothing here depends on the clock.)
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
- **Aggregates by value** — struct arguments and struct returns — are refused
  at compile time: DOOM passes every aggregate by pointer. (Had they been
  needed: struct args copied to the stack, returns through a hidden pointer in
  R0.) Whole-struct assignment is a byte copy.
- **Varargs**: the *caller* stores every argument — R0–R3 into the home area
  as well as 5+ on the stack — so at the `BL` the whole list lies contiguous at
  `SP+0…`. A variadic callee takes FP and walks it upward from `FP + 4·(fixed
  params)`; `va_list` is a `char*`, and the callee's prologue costs nothing.
  Hand-written code calling a variadic function must store R0–R3 too (the
  drawers' `I_Error` calls do).
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

- A function sets up FP only when it reads incoming stack arguments (more than
  four parameters, or variadic); locals are SP-relative — SP is fixed for the
  whole body, since DOOM has no `alloca` or VLA. Leaf functions may skip the LNK
  save and the frame entirely.
- Oberon compatibility: ORG also evaluates the first parameters into R0… —
  for the ≤3-arg blob entries the conventions coincide at the boundary; the
  crt0 thunks (§7) own everything else.

## 4. C type metrics

| | |
|---|---|
| char | 8-bit **unsigned** (chocolate-doom lineage is already clean here) |
| short | 16-bit |
| int, long, pointers | 32-bit |
| long long | **does not exist** (refused by `lib/check.ml`). DOOM's only 64-bit code is `m_fixed.c`'s `FixedMul`/`FixedDiv`, which doomcc replaces wholesale: `FixedMul` is the §5 intrinsic, `FixedDiv` is 32-bit C (`libc/fixed.c`). The other refused 64-bit functions are glibc header inlines (`__bswap_64`, `__uint64_identity`) that nothing calls |
| float, double | **no runtime floating point** (refused). Constant `double` expressions under an integer cast fold at compile time (am_map's `(int)(.867 * 65536)` idiom); the one runtime use that matters, the timedemo's fps print, is patched to integers (`patch/c/0001`); the rest is unreachable (no config file, no mouse) and refused. The RISC5 FPU exists if ever needed |
| alignment | natural, max 4; stack and structs word-aligned |
| packed | `PACKEDATTR` is `__attribute__((packed))` under gcc, so packed structs reach CIL and are laid out byte-exact. A word access at a misaligned offset is refused at compile time — `LDW`/`STW` drop the low two address bits |
| bitfields | **byte-aligned `:8` fields only** — one addressable byte each, accessed with `LDB`/`STB` (DOOM's only bitfield struct, `struct color`, is four of them); any other width or offset is refused |

## 5. Runtime helpers and intrinsics

Helpers (hand-written, `lib/runtime.ml`) — standard ABI calls; the division and
shift helpers touch only R0–R3, H and the flags:

| Symbol | Contract |
|---|---|
| `__div`, `__mod` | signed truncating `/` `%`; wrap hardware DIV (negate-before / fix-after); full sign coverage; a zero divisor yields 0 |
| `__udiv`, `__umod` | unsigned; one `DIV'` (exact for any dividend), plus the path for divisor ≥ 2³¹ (quotient 0 or 1) |
| `__lsr` | logical `>>` by a variable count (RISC5 has no logical shift right) |
| `__setjmp`, `__longjmp` | the unwind behind `exit()` (§7): a 9-word buffer of R6–R12, SP, LNK |

The backend maps C `/` and `%` to these calls; it never emits a bare `DIV`.
`FixedDiv` is ordinary C (`libc/fixed.c`, ~200 cycles); `mem*` are the
mini-libc's compiled C (`libc/mini.c`, with a word-copy fast path in `memcpy`).

**Intrinsics** (an `instr list → instr list` pass, §6) — registry frozen
at: `{ FixedMul }`. A `FixedMul` call expands inline (6 instructions:
`MUL`, `MOV'` from H, `LSL`/`ROR`/`AND`/`IOR`), result in R0, clobbers
R0–R1 + H + flags — within the ABI's notion of a call, so callers can't
tell (except by being fast).

## 6. The assembler/linker layer (over risc5_isa)

The canonical representation is `Risc5_isa.instr`: the instr ADT +
`encode`/`decode` + field accessors, the single definition of the RISC5
encoding, shared by the compiler, this layer and the emulator's own decoder
(it lives in the emulator,
[`risc5_isa.mli`](vendor/oberon-risc-hardcaml/vendor/oberon-risc-emu-ocaml/lib/risc5_isa.mli),
which the host repo vendors). The backend emits `instr` lists directly, and the
hand-written code (`lib/asm.ml`'s eDSL) constructs the same values, so
compiled and hand-written code link freely. Nothing round-trips through text.

So the "assembler" is not a parser but an **instr-level linker** — a small
pipeline of `instr list` passes:

- **Label/branch resolution** — symbolic labels (a DOOM-repo layer *above*
  risc5_isa; `risc5_isa.instr` itself carries resolved offsets only) become
  concrete PC-relative / DB-relative offsets; forward refs are a two-pass.
- **Pseudo / intrinsic expansion** — an address `Rd := label` → `MOV'`+`IOR`
  (always 2 words, so layout never depends on resolved values); the `FixedMul`
  intrinsic (§5) → its 6-instruction inline.
- **Addressing** — register aliases `FP DB SP LNK` (§2); global data is
  DB-relative; an absolute address is placed as a data word.
- **Section layout** — code / data / bss flattened in order; bss reserves
  without emitting; the flat image links at a fixed himem address (§8), no
  relocation.
- **Header + map** — auto-emit the §7 header (lengths, entry offsets from
  the crt0 entries, checksum); dump a symbol map (`doom.blob.map`).
- **Pointer-valued data** — an initializer holding a data or code address is
  patched to the absolute word at link time.

Never built, and not needed: a text parser (text → instr) or a disassembler
(instr → text). Both producers make `instr` values, so text would only ever be a
view. The leaf below is written in assembly notation for reading; the eDSL
builds exactly this list:

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
save R6–R15 → save area at the bss end   ; Oberon's world, parked
SP  = STACK_TOP ; SUB SP, SP, 16         ; C stack + initial home area
DB  = LEA DB, __data_base
BL   <C entry>                            ; args already in R0/R1 (§3)
restore R6–R15
B    LNK                                  ; back to the stub
```

Signatures: `Init(wad_addr, cfg_addr) → 0 | error code`;
`Tick() → 0 continue | 1 quit`; `KeyIn(ev)` enqueues one key event —
`ev = pressed | doomkey << 8`, the §8 ring byte order. `exit()`/`I_Error` set status in the shared
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
that grows past `0x2C0000` corrupts .bss silently. Nothing measures DOOM's
worst-case depth (BSP recursion); 256 KB is a wide margin for it, and doomcc
refuses a blob whose bss would reach the stack's row.

SHARED page (v1 fields; rest reserved):
`+0`, `+4`, `+8` unused — named magic, version and flags at the freeze, never
written by any loader (the Cyclesim boot ROM borrows `+4` as its tick target and
`+8` for its progress markers, `bin/emit_rom.ml`) · `+12` blob status
(0 running, 1 quit, negative = I_Error code) · `+16` frame counter
(heartbeat, incremented by `Tick`) · `+20` key ring head · `+24` tail ·
`+28` WAD length in bytes (stub writes before `Init`) · `+32…` ring of
2-byte events (make/break, code), 256 entries · `+1024…` the **command
tail**: NUL-terminated text, ≤ 3 KB — the loader writes the raw tail
verbatim before `Init` (a zeroed page is the empty tail; no parsing on the
loader side — DOOM.Mod copies the rest of the command's line, up to `~` or the
line's end; run_blob copies its `-args` string). `Init` prepends the baked
`doom -iwad doom1.wad` and tokenizes on blanks **in place** (writing NULs),
so the region belongs to the blob after `Init` — `myargv` points into it.

Key-ring discipline (v1; a §10 non-breaking clarification of the fields
above): head and tail are free-running u32 counters, masked at use
(index = counter & 255) — empty is `head = tail`, full is
`head − tail = 256`, both exact across the u32 rollover. The producer
(the blob's `KeyIn`) writes the 2-byte event at
`+32 + 2·(head & 255)`, *then* increments head; the consumer (the blob's
`DG_GetKey`) reads at `+32 + 2·(tail & 255)` when `tail ≠ head`, then
increments tail. A full ring drops the event, producer-side. Event bytes:
byte 0 = pressed (1 make, 0 break), byte 1 = doomkey code (`doomkeys.h`) —
the sender owns all translation; the blob never sees a scancode. The stub
zeroes the SHARED page (head = tail = 0) before calling `Init`.

SHARED `+544` (a §10-non-breaking reserved-field addition): the
**presentation flags**, loader-written before `Init`. Bit 0 = present through
the Halftone hardware (zero, the default, is the software dither). Bit 1 =
viewer presentation: the *stub* owns mode + geometry; the blob keeps
thresholds + LUT + frame copy (§11). DOOM.Mod sets bit 0 only after finding
the hardware (its frame counter, §11, advances).

## 9. Assumptions the freeze rests on, and how each came out

- **C1** — interrupts never fire (else the R12/H/flags rules change). Holds:
  interrupts are disabled from reset, and neither Project Oberon 2013's system
  modules nor the blob enable them.
- **C2** — whether loads set N/Z. Moot: the backend derives every condition
  from an explicit compare or ALU op, and the hand code consumes a flag in the
  instruction right after the op that set it.
- **C3** — `DIV'` (unsigned) with divisor ≥ 2³¹ is out of the divider's range.
  Confirmed; `__udiv`/`__umod` handle it (§5).
- **C4** — `MUL'` (unsigned) H semantics. Moot: the backend emits signed `MUL`
  for every multiply (the low word is the same), and H is read only after
  `FixedMul`'s signed `MUL`.
- **C5** — `MOV'` reading H (v=0) vs the flags (v=1). The H read is used —
  `FixedMul` and the division helpers — and exercised by the jig's fixed-point
  and division samples and every frame; the flags read is unused.

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
(§8); SHARED `+544` presentation flags + **§11**, the Halftone display seam
(2026-07-15, after the mode shipped).

v1-final errata (2026-10-26, the release): the text now matches what was
built, where it had described plans — §3's varargs rule (the caller stores
the arguments, not the callee), its aggregate rule (by-value structs are
refused, not copied) and when FP exists, the type metrics (§4: packed structs and
byte-aligned `:8` bitfields are supported, `FixedDiv` is C), the helper table
(§5), the linker's passes (§6), SHARED `+0`/`+4`/`+8` (§8: never written), the
C1–C5 outcomes (§9). No field or offset changed, and no code: every
correction is the text catching up with the implementation.

## 11. The Halftone display seam (shipped 2026-07-14; v1-additive)

The generalized indexed/grayscale display mode — hardware: the host repo's
`Halftone` (`board/nexys-4/halftone.{ml,mli}`);
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
| `+0 .. +63999` | pixel bytes — **meaning is client-defined**: the row map names each displayed row's byte offset, so 320×200 row-major, strided images, or a double-buffered pair are all just row maps. Clients render **complete frames** here — the raster must never watch a renderer mid-sweep |
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

Mode discipline (fullscreen, blob-owned): upload thresholds +
row map + LUT + geometry, then **mode on at the first `DG_DrawFrame`**
(never at Init), **off in `exit()`** (instant desktop restore — the mono
framebuffer was never written). Mode-on over zeroed tables scans all-zero
thresholds: every non-black pixel white; upload first. Under SHARED `+544`
bit 1 (§8) the stub owns mode + geometry instead: `DOOM.Run -win`'s viewer
lifecycle re-`Open`s the largest 4:3 rect per ModifyMsg, and quit/suspend
drop the mode.

Arbitration (`Halftone.Mod` policy — the hardware stays pure mechanism): the rect is **single-owner at consumer lifetime** — `Claim` takes
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
