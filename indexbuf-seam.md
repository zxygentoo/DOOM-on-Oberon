# indexbuf-seam.md — DRAFT v2 (feat/indexbuf; not part of frozen ABI v1)

The seam for the **generalized indexed/grayscale display mode** — the host
repo's `Indexbuf` (boards/nexys-4/indexbuf.{ml,mli}) and this repo's software
side (libc hw path, `stub/Halftone.Mod`, doom_sim -hw). v1 of this seam was
the fps-lever-#3 experiment: DOOM's dither moved into scanout hardware, with
the 320×200 → fullscreen geometry *baked* into the design. v2 is the
generality rework (review round 2026-07-14): **the hardware keeps only
mechanism; every policy — tone, thresholds, and now geometry — is uploaded
by the client at runtime.** DOOM demotes to one client among any Oberon
program that wants grayscale pixels on the 1-bit panel. Draft-grade on
purpose: these constants live here and in `Indexbuf`'s mli, and are promoted
into ABI.md (§10 version bump) only if the mode ships.

What "content-free" now covers (v1 → v2):

| | v1 (experiment) | v2 (this design) |
|---|---|---|
| tone map (LUT) | uploaded | uploaded (unchanged) |
| threshold map | uploaded, as 2048 pre-packed *slot quads* (the 3/3/3/3/4 packing leaked into the upload format) | uploaded **verbatim**: 4096 plain bytes, 64×64 row-major |
| vertical geometry | baked ROM (320×200→768 Bresenham + out2 dealing) | uploaded **row map**: 768 × `{thr_row, row_base}` words |
| horizontal geometry | baked slot tables (3.2× only) | 3 registers: `XNUM/XDEN/XOFF`, an exact output-driven DDA |
| panel coverage | fullscreen only | **overlay rect** `WIN_X/Y/W/H`, word-aligned in x, composed against the mono `Framebuf` per request |
| frame sync | none | vblank flag + frame counter, CPU-readable (MMIO), geometry registers vsync-latched |

## The pixel window (64 KiB at `IXB_BASE = 0x310000`)

ABI §8's back-buffer row, repurposed — unchanged from v1. The board shadows
every PSRAM-bound store in the window (write-through, the Framebuf/cache tap:
`wr & ~cpu_internal`); PSRAM keeps the truth, CPU loads are untouched.

| byte offset | contents |
|---|---|
| `+0 .. +63999` | pixel bytes. **Meaning is client-defined**: the row map (below) names each displayed row's byte offset in this window, so 320×200 row-major (DOOM), a narrower image with a stride, or a double-buffered pair of half-height images are all just different row maps. Clients render **complete frames** here (DOOM: `DG_DrawFrame`'s block copy, drawer #5 — the board flicker lesson, 2026-07-10: the raster must never watch a renderer mid-sweep) |
| `+64000 .. +64255` | tone LUT: index = pixel byte, value = 8-bit gray (DOOM: gamma-folded sum-256 luminance; identity ramp = a grayscale framebuffer) |
| `+64256 ..` | the register block, word offsets below |

### The register block (`IXB_CTL = base+64256`; word stores)

| reg | offset | width | semantics |
|---|---|---|---|
| `CTL` | +0 | bit 0 | mode: 1 = the rect scans out from this window through the dither FSM. **Immediate** (not latched) — `exit()`'s instant desktop restore depends on it |
| `WIN_X` | +4 | 11 | rect left edge, panel px, **multiple of 32** (the claim mux selects whole fb words — no bit-merge exists) |
| `WIN_Y` | +8 | 10 | rect top edge, panel px (any) |
| `WIN_W` | +12 | 11 | rect width, px, **multiple of 32**, `X+W ≤ 1024` |
| `WIN_H` | +16 | 10 | rect height, px, `Y+H ≤ 768` |
| `XNUM` | +20 | 12 | horizontal scale numerator (output px per `XDEN` source px). **`XNUM ≥ XDEN ≥ 1`** — upscale or 1:1 only; the DDA advances the source at most one byte per output px |
| `XDEN` | +24 | 12 | horizontal scale denominator |
| `XOFF` | +28 | 16 | starting source byte column: the DDA seeds `sx := XOFF` at each rect row start (pixel address = `row_base + sx`) — horizontal pan is one register write |

All geometry registers (`WIN_*`, `XNUM/XDEN/XOFF`) are **shadowed**: a store
writes the shadow; the hardware copies shadow → active **once per frame at
vblank entry**, so a mid-frame `Open` never tears. The row map / threshold /
LUT RAMs are live — the client's discipline is to rewrite them **during
vblank** (`Halftone.Sync`; the blanking window is ~600 µs at 60 MHz, a 768-word
row map re-upload is ~µs) or with the mode off. Registers are **write-only**
(CPU loads of the window return PSRAM truth, not module state); status reads
live on MMIO (below). Power-up state is all-zero: a zero-sized rect claims
nothing, so even a stray mode-on displays nothing — mode-off elaboration
stays display-identical to a board without the module (the do-no-harm gate).

## The table window (8 KiB at `IXB_THR = 0x30E000`, carved from the §8 spare row)

The hardware ships no dither map and no geometry. Before mode-on the client
uploads both:

| byte offset | contents |
|---|---|
| `+0 .. +4095` | **threshold map, verbatim**: 64×64 bytes, row-major (`byte = map[row*64 + col]`). The v1 slot-quad packing (and its K=3 pad-255 kludge) is gone — DOOM stores `__dg_bn64` as-is, byte or word stores both work |
| `+4096 .. +7167` | **row map**: 768 words, entry `y` = the rect-relative output row: bits `[15:0]` = `row_base`, the source row's byte offset in the pixel window; bits `[21:16]` = `thr_row`, the threshold-map row for that output line. **Word stores only** (one RAMB36; no byte lanes) |
| `+7168 .. +8191` | reserved |

The row map is the load-bearing generalization: any vertical scale, any
dealing — 200→768 Bresenham, 1:1, 2×, a double-buffer flip (rewrite
`row_base`s), even interleave — is a software loop filling ≤768 words, and
**no multiplier, divider, or vertical DDA exists in hardware**. It is also
what keeps the pixel oracle alive: DOOM uploads the exact out2 dealing
(`thr_row = (2·sy + i) & 63`, `i` alternating over each source line's 3-or-4
output rows), so the hardware stays **bit-identical to `__dg_dither_fs`** and
every existing golden. `thr_row = y & 63` (the identity map) is the full
per-output-decision quality knob, now a runtime choice behind a contact
sheet.

## The decision function and the horizontal DDA (exact)

Per output pixel of a claimed word: `bit = (lut[pix[row_base + sx]] >
thr[thr_row][ox & 63])`, `ox` = panel x, bit 0 of a word = leftmost (Oberon).
`sx` advances by the output-driven DDA, **frozen as**:

```
row start (first claimed word of a rect row):  sx := XOFF;  acc := XDEN
per output pixel:  emit(sx);  acc := acc + XDEN;  if acc > XNUM { acc := acc − XNUM; sx := sx + 1 }
```

At `XNUM/XDEN = 16/5` this deals source widths 3,3,3,3,4 — exactly
`__dg_dither_fs`'s slot tables (a host-repo test asserts the DDA ≡ the v1
`xw/xoff` tables over a full row; the full-frame hash test then pins the
whole pipeline). At `XNUM = XDEN` it is the identity. `acc` state carries
across the words of a row (video requests every visible word in raster
order; rect words are consecutive), and the FSM's 2-word source window
carries with it, so mid-row words need no priming reads.

## The overlay rect and the claim mux

Per video request the module computes `claim = mode ∧ (y_req < 768) ∧ (y_req,
col) ∈ rect`, latched at request-accept. The board mux forwards
`viddata/vid_ack/vidpar` from `Indexbuf` when the completing request was
claimed, from `Framebuf` otherwise — **per request**, replacing v1's
whole-screen mode mux. Fullscreen rect ≡ v1 behavior. Unclaimed requests
never start the compose FSM. The mono framebuffer keeps shadowing every
store as always; inside the rect its content (including the Oberon mouse
pointer) is simply not displayed — **v1 non-goal, written down**: a client
that wants a live cursor over its pixels draws one into the pixel window
itself. Blanking-time fetches (`y_req ≥ 768`, the prefetch's wrap rows) are
never claimed.

## Frame sync — the status register (MMIO `0xFFFFE8`, read-only)

Video issues **no fetches during vertical blanking** (`req0` is gated with
`~vblank` — lib/video.ml), so blanking is visible at this seam as a
**request gap**: ~47k clk of silence against ~300 clk for the longest
in-frame gap (hblank). A saturating 12-bit watchdog detects it — entry fires
~68 µs into the ~786 µs blanking — with **no CDC and no Video changes**:
bit 0 = vblank, bits `[15:8]` = an 8-bit frame counter (increments at vblank
entry — the same edge that latches the geometry shadows). Wired into the
SoC's MMIO read mux at the free slot 10 (`0xFFFFC0 + 40`). This is the
machine's first readable frame clock; `Halftone.Sync` busy-waits on the
vblank edge, and any animation client can pace on the counter.

## Mode discipline (blob-owned in v1, §5 blob-talks-MMIO)

Unchanged in shape from v1, with geometry joining the upload set: thresholds
+ row map + LUT + geometry registers written, then **mode on at the first
`DG_DrawFrame`** (never at Init — first-frame gating makes TITLEPIC appear
exactly when it does today), **off in `exit()`** (instant desktop restore —
the mono framebuffer was never written). Mode-on with a zeroed table window
scans all-zero thresholds: every non-black pixel renders white. Upload
first.

## The presentation flag (SHARED `+544`, bit 0) — unchanged

Loader-written before Init. Zero (every existing loader/harness) = software
dither, bit-identically unchanged. 1 = the hardware is present: `DG_Init`
latches it, `DG_DrawFrame` becomes frame copy + LUT-on-palette-change +
(once) thresholds/row-map/geometry upload + mode-on.

**v2 viewer citizenship (IMPLEMENTED for output, 2026-07-14):** SHARED +544
**bit 1 = viewer presentation** — the blob's hw path keeps only frame copy +
LUT + threshold upload; the *stub* owns mode and geometry. `DOOM.Window`
opens a MenuViewers viewer ("System.Close" menu): an `Oberon.Task` calls
`Tick` once per loop pass, the frame handler + a `V.state` poll run the
Mandel.Mod lifecycle (ModifyMsg → drop mode, next displayed tick re-`Open`s
the largest 4:3 rect — w aligned, h = w·3/4, scale w/320 gcd-reduced;
suspend → off; close → off + task removal; quit/I_Error → viewer closes).
The desktop stays live around the game. **Keys are point-to-play** (the §6
v2 input slice, 2026-07-14): `stub/Input.Mod.patch` (applied by mkdisk,
the agent-autoload precedent) adds `Input.SetSink` — a raw-scancode tap
that, while set, receives the untranslated make/break stream inside
`Peek` and silences the translated path (NIL = stock, byte-identical).
The stub registers its `Byte` FSM (the same one the seize loop drains the
FIFO through) exactly while the pointer is over the game frame: park the
mouse on DOOM to play with full arrows/modifiers fidelity, move it off
and the keyboard is Oberon's again — the Log stays typable mid-game.
Events land in the blob's key ring from Oberon.Loop's own input polling,
between ticks, exactly like the seize loop's PollKeys. Fullscreen
`DOOM.Run`/`RunHW` (bit 1 clear) are byte-identically unchanged.

## The software faces

- **DOOM blob** (`libc/dither.c` + `libc/doomgeneric_oberon.c`, raw MMIO):
  `__dg_upload_thresholds` = copy `__dg_bn64` verbatim (word stores);
  `__dg_upload_geometry` = the out2 row map (`row_base = sy·320`, `thr_row`
  = the out2 dealing — the same 20-line Bresenham as the software kernel) +
  fullscreen rect + `16/5/0`.
- **`stub/Halftone.Mod`** (in-image Oberon-07, the module face for Oberon
  clients): `Open(x, y, w, h, xnum, xden, xoff)` (validates alignment and
  `XNUM ≥ XDEN`, writes the shadows) · `LinearRows(srcH, stride)` (Bresenham
  dealing, per-output `thr_row = y MOD 64`) · `SetTone` / `ToneIdentity` ·
  `SetThresholds` / `Bayer8` · `On` / `Off` · `Sync` (vblank wait) ·
  `Frame()` (the counter). Single-owner by construction — there is exactly
  one rect in hardware; the doc is the arbiter (like the Oberon focus).
- **`stub/Mandel.Mod`** — rewritten as `Halftone`'s first client (drops its
  own quad packing and MMIO constants): the generality witness stays two
  clients deep with zero shared content.

## Verification (the rungs, v2)

1. **DDA ≡ slot tables** (host, new): the frozen DDA at 16/5 reproduces
   `xw/xoff` over a full row; the C row-map builder ≡ the v1 ROM contents.
2. **Model ≡ the shipped C kernel** (host, kept): full-frame FNV hash of the
   reference model at the DOOM configuration — **the hash constant
   `b66f831b508c374f` must not move** across the rework (same pixels through
   uploaded tables instead of baked ROMs).
3. **Hardware ≡ model differential** (host, extended): random uploads through
   the real ports — now including **random geometry** (rects, scales,
   XOFF, row maps) — every fetched word diffed; unclaimed fetches assert
   `claim = 0`; shadow-latch semantics pinned (a mid-frame geometry write
   takes effect only after a blanking fetch); status register progression.
4. **Board gates** (DOOM repo, kept): mode-off byte-identical visual golden
   (INDEXBUF=1); doom_sim `-hw` captured scanout ≡ the host golden
   bit-identical (the out2 row map transfers the oracle); jig, goldens ×4,
   5026 exact; dskrun `-ixdump`; Mandel on the booted OS.

## Cost / plumbing summary (v2 targets)

BRAM ≈ v1's ~18 BRAM36-equivalent (thr shrinks 8→4 KiB, the row map takes
one RAMB36, the v1 row-map/geometry ROMs go away; pixel shadow 16 unchanged).
Compose stays request-driven, 4 output px/clock (one aligned 4-lane threshold
read per clock, fixed nibble accumulation — the v1 variable shifter dies), a
2-word sliding source window (1 pixel read per clock, carried across a row);
~13 clk vs Video's ~29.5-clk sustained spacing, worst case (1:1) included.
Timing discipline per the v1 lessons: registered BRAM outputs everywhere, the
4-wide DDA chain is the new path to watch, WNS margins are thin (+0.031
history) — budget a rebuild iteration.
