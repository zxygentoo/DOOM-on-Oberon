# indexbuf-seam.md — DRAFT (feat/indexbuf experiment; not part of frozen ABI v1)

The seam for **fps lever #3: the dither moved into scanout hardware** — the
host repo's `Indexbuf` (boards/nexys-4/indexbuf.{ml,mli}, the 10c `Framebuf`
pattern applied to an indexed-colour buffer) and this repo's software side
(libc/doomgeneric_oberon.c hw path, patch 0004, doom_sim -hw). Draft-grade on
purpose: these constants live here and in `Indexbuf`'s mli, and are promoted
into ABI.md (§10 version bump) only if the experiment ships.

## The window (64 KiB at `IXB_BASE = 0x310000`)

ABI §8's back-buffer row, repurposed — the software path stopped using it as a
copy target when patch 0003 aliased `DG_ScreenBuffer = I_VideoBuffer`. The
board shadows every PSRAM-bound store in the window (write-through, the
Framebuf/cache tap: `wr & ~cpu_internal`); PSRAM keeps the truth, CPU loads
are untouched (the wipe's read-back path works unchanged).

| byte offset | contents |
|---|---|
| `+0 .. +63999` | 320×200 pixel bytes, row-major, row 0 = top of the image. The renderer composites OFF-SCREEN (zone buffer) and `DG_DrawFrame` block-copies the finished frame here — the double buffer DOOM assumes (board lesson 2026-07-10: direct composite let the raster watch the renderer mid-sweep — constant-rate flicker; `__dg_fixed_vbuf`/patch 0004 stays as an unused seam) |
| `+64000 .. +64255` | luminance LUT: index = palette byte, value = 8-bit luminance (gamma-folded, sum-256 weights — `__dg_lum`, uploaded by `DG_DrawFrame` on `palette_changed`) |
| `+64256` | control word: bit 0 = mode (1 = the panel scans out from this buffer through the dither FSM; 0 = the mono `Framebuf` path, stock Oberon) |

## The threshold window (8 KiB at `IXB_THR = 0x30E000`, carved from the §8 spare row)

The hardware is **content-free**: it ships no dither map. Before mode-on,
every client uploads its 64×64 threshold map as **2048 slot quads**, word
`a = row·32 + phase·16 + slot`: the slot's 3-or-4 thresholds one byte each
(LSB = leftmost output bit; slots cover 3/3/3/3/4 output bits at offsets
0/3/6/9/12 within each 16-bit phase; K=3 slots pad byte 3 with 255 — a
compare an 8-bit luminance can never win; the threshold column of output bit *b* is
`32·phase + b`). Implementations of the packing: `slot_quad` (host-repo
tests), `__dg_upload_thresholds` in `dither.c` (DOOM's blue noise),
`Mandel.Upload` in `stub/Mandel.Mod` (a computed Bayer 8×8). **Mode-on
without a prior upload scans all-zero thresholds: every non-black pixel
renders white.**

Mode discipline (blob-owned, §5 blob-talks-MMIO): thresholds + LUT uploaded,
then **on** at the first `DG_DrawFrame` (never at Init — first-frame gating
makes TITLEPIC appear exactly when it does today), **off** in `exit()` —
which restores the desktop instantly, since the mono framebuffer was never
written.

## The second client (the generality witness)

`stub/Mandel.Mod` — an ordinary Oberon command sharing zero code and zero
content with DOOM: REAL-arithmetic Mandelbrot into the pixel window, identity
LUT, its own computed Bayer rendition uploaded to the threshold window, mode
on, any-key exit, instant desktop restore. `Mandel.Draw` in System.Tool.

## The presentation flag (SHARED `+544`, bit 0)

Loader-written before Init, in the free gap after the key ring (+32..+543).
Zero (every existing loader/harness) = software dither — `doomrun`, `dskrun`,
the stub, and all goldens run bit-identically unchanged. 1 = the hardware is
present: `DG_Init` latches it, and `DG_DrawFrame` becomes threshold upload
(once) + frame copy + LUT-on-palette-change + mode-on (once). (`+8` was ABI's
reserved flags word, but the doom_sim contract already uses it as the
Init/done marker channel — hence +544.)

## The decision function (frozen by tests, not prose)

Hardware ≡ `dither.c`'s `__dg_dither_fs` (out2, weights via the uploaded LUT),
pinned by four rungs: the host-repo co-located hash test (OCaml model ≡
gcc-compiled dither.c, full frame), the 300-word hardware ≡ model
differential, the mode-off byte-identical `@visual_golden_board`
(INDEXBUF=1), and doom_sim's captured-scanout frame ≡ the host golden
(`-hw`). Quality note: scanout hardware gets per-output-pixel decisions for
free; the FSM implements out2 *exactly* anyway so the pixel oracle transfers
— full per-output is a one-ROM-change quality knob behind a contact sheet.

## Cost/plumbing summary (as measured, 2026-07-10)

Host repo: `Indexbuf` — one self-contained module (793 lines incl. tests +
oracle data), board-layer only, `lib/` and `Video` untouched, no new CDC (all
60 MHz clk domain, the vidreq seam). ~18 BRAM36-equivalent: 16 pixel-shadow +
4 threshold-lane RAMB18 + the row-map ROM. Compose latency 12 clk vs Video's
~59-clk budget / ~29.5-clk sustained spacing; build 3 closes at WNS
+0.066/+0.096. DOOM repo: `__dg_upload_thresholds` + the
`DG_DrawFrame`/`DG_Init`/`exit` hw path + `__dg_lum` exported (+patch 0004,
inert). Measured: **silicon 12.2 fps** (was 8.3; Cyclesim 4.25 Mcyc/tick =
14.1 model-ideal — the gap is the frame copy's naive-compiled word loop, a
hand-rolled copy drawer reclaims ~1.5–2 fps if wanted) — and `Mandel.Draw`,
the second client, proves the mode general on the same silicon.
