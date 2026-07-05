# SEAM.md — the 3a spec (ABI · asm · blob format · himem layout)

**Status: DRAFT — freezes as v1 after review. The freeze is the deliverable.**

Consumers: the OCaml backend (1b), hand-rolled asm (1a), the shared-ISA
assembler layer (3b), stub loader (2c), sim harness (1d), Oberon
prototypes (2b). Every constant
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

Review knob (pre-freeze only): the 6/6 caller/callee split of R0–R11.
More temps ease expression pressure in the backend's naive first cut;
more regvars pay off as the allocator ladder climbs (naive → local →
linear-scan). Hand-rolled leaves don't care — they use caller-saved
registers freely and save nothing.

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
| long long | **does not exist** (banned by policy; `m_fixed.c` replaced wholesale) |
| float, double | **banned in the blob v1** (the amalgamation pass removes the strays; RISC5 single-precision FPU exists if ever needed) |
| alignment | natural, max 4; stack and structs word-aligned |
| packed | **no packed attribute** — `PACKEDATTR` defined empty; every WAD-facing struct gets a `sizeof` assert in the host reference build |
| bitfields | avoid in on-disk structs (DOOM doesn't use them there) |

## 5. Runtime helpers and intrinsics

Helpers (hand-rolled, 1a) — standard ABI calls, clobber caller-saved only:

| Symbol | Contract |
|---|---|
| `__div`, `__mod` | signed truncating `/` `%`; wrap hardware DIV (negate-before / fix-after); full sign coverage |
| `__udiv`, `__umod` | unsigned; fast path hardware DIV, slow path for divisor ≥ 2³¹ (quotient is 0 or 1) |
| `FixedDiv` | `(a<<16)/b`, 48/32 software long division, ~200–300 cycles |
| `memcpy`, `memset`, `memmove` | word-loop cores |

The backend maps C `/` and `%` to these calls; it never emits a bare `DIV`.

**Assembler intrinsics** — registry frozen at: `{ FixedMul }`.
`BL FixedMul` expands inline (≈6 instructions: `MUL`, `MOV'` from H,
`LSL`/`ROR`/`AND`/`IOR`), result in R0, clobbers R0–R1 + H + flags — within
the ABI's notion of a call, so callers can't tell (except by being fast).

## 6. Assembler input language (what 3b's parser consumes)

Hand-written 1a code arrives as this text (or as the OCaml eDSL over the
same instr type); the backend emits shared-ISA instrs directly and never
round-trips through the text form.

- One instruction per line; `;` comments; labels `name:`; locals `.Lname`.
- Registers `R0…R15` + aliases `FP DB SP LNK`; immediates decimal or `0x…`.
- Mnemonics = the RISC5 architecture doc's, `'` for u-variants:
  `MOV LSL ASR ROR AND ANN IOR XOR ADD SUB MUL DIV` (+ immediate forms,
  16-bit, v-bit sign-fill); `MOV' Rd` reads H; `LDW LDB STW STB Rd, Rn, off`;
  `B BL BEQ BNE BLT BGE BLE BGT BMI BPL BCS BCC BVS BVC BLS BHI` — operand a
  label (PC-relative) or a register (register branch; `B LNK` is return).
- Label uses, exactly three: branch target (automatic PC-rel); `@label` =
  DB-relative offset for mem ops (`LDW R0, DB, @myglobal`); `.word label` =
  absolute address in data. Loading an address into a register:
  pseudo `LEA Rd, label` (expands to `MOV'`+`IOR`, 2 words).
- Directives: `.code .data .bss name,size .align n .word .byte .space n
  .asciiz "…"`. Sections are flattened in order: header, code, data;
  `.bss` reserves without emitting bytes.
- Predefined symbols: `__data_base __bss_start __bss_end __image_end`.
- No macros, no expression grammar (`label` and `label+const` only). The
  intrinsic expansion (§5) is the single piece of magic.
- Output: flat image at `BLOB_BASE` with the header (§7) auto-emitted —
  the assembler fills lengths, entry offsets (from the crt0 labels
  `crt_init`/`crt_tick`/`crt_keyin`), and checksum. Also emits a listing
  and a symbol map: the debugging currency of the whole project.

Worked example (leaf, caller-saved regs only, no frame):

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
UART itself, §6 of DOOM.md). `exit()`/`I_Error` set status in the shared
page and return through the thunk — never halt.

## 8. Himem layout v1 (the constants page)

Oberon owns `[0, 1 MB)` — stock kernel, 1 MB worldview, never touches
himem. Top of the 16 MiB space (`≥ 0xE00000`) is left untouched (ROM/MMIO
decode territory + margin).

| Base | End | Size | Contents |
|---|---|---|---|
| `0x100000` | `0x2C0000` | 1.75 MB | **BLOB**: header, code, data, .bss (cap) |
| `0x2C0000` | `0x300000` | 256 KB | **C stack**, grows down from `STACK_TOP = 0x300000` |
| `0x300000` | `0x301000` | 4 KB | **SHARED page**: cfg in, status out, key ring |
| `0x301000` | `0x310000` | 60 KB | spare |
| `0x310000` | `0x320000` | 64 KB | **back buffer** (320×200×8 = 64 000 B) |
| `0x320000` | `0x400000` | 896 KB | spare (wipe buffers, LUTs, growth) |
| `0x400000` | `0xA00000` | 6 MB | **zone** (DOOM's Z_Malloc block) |
| `0xA00000` | `0xE00000` | 4 MB | **WAD** (chunks concatenated by stub) |

No hardware guard pages exist; the blob/stack gap is convention. A stack
that grows past `0x2C0000` corrupts .bss silently — the jig's stack-depth
test (BSP recursion worst case) is the insurance.

SHARED page (v1 fields; rest reserved):
`+0` magic · `+4` version · `+8` flags (reserved) · `+12` blob status
(0 running, 1 quit, negative = I_Error code) · `+16` frame counter
(heartbeat) · `+20` key ring head · `+24` tail · `+32…` ring of 2-byte
events (make/break, code), 256 entries.

## 9. Confirm-in-sim checklist (becomes the first jig vectors)

- **C1** — interrupts genuinely never fire (else R12/H/flags rules change).
- **C2** — whether loads set N/Z (we forbid relying on it either way).
- **C3** — `DIV'` (unsigned) with divisor ≥ 2³¹: confirmed-unsupported;
  helper slow path covers it.
- **C4** — `MUL'` (unsigned) H semantics vs the signed case.
- **C5** — `MOV'` variants: H read (v=0) vs flags read (v=1) encodings.

## 10. Freeze protocol

Until frozen: edit freely, this file is the argument. After: the register
map, calling convention, type metrics, header offsets 0–35, and the layout
table are **v1-frozen** — changes mean `version = 2` and a conscious
migration of every consumer. Additions to reserved header/SHARED fields and
new assembler directives are non-breaking.
