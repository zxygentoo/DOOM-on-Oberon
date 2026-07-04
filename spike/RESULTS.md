# CIL spike results — DOOM.md §9 gate

**Verdict: GREEN.** goblint-cil swallows doomgeneric whole.

Run: `./fetch-doomgeneric.sh && ./preprocess.sh && dune exec bin/merge_doom.exe -- out/i/*.i`
(driver built on the `default` opam switch, OCaml 5.3.0, goblint-cil 2.1.0 —
the `5.2.0+ox` OxCaml switch can't resolve goblint-cil's deps).

## Numbers

| | |
|---|---|
| TUs (Makefile `SRC_DOOM` minus the platform TU) | 80 |
| parsed | **80 / 80** |
| `Mergecil.merge` | **clean** |
| function defs | 1 184 |
| global var defs | 982 |
| CIL instrs / stmts | **12 080 / 13 311** |
| alpha-renamed globals | 220 = 210 glibc-header dups + **10 DOOM-real** |
| merged TU | 76 334 lines of C |
| roundtrip `gcc -std=gnu99 -c` | **OK** (911 KB .o with debug info) |

The 10 DOOM-real file-scope collisions (`anims`, `buf`, `filename`, `y`,
`mousex`, `mousey`, `plr`, `oldgamestate`, `fullscreen`, `st_notify`) are the
entire manual-rename problem PureDOOM solved by hand — Mergecil renames them
automatically. The 210 `__`-prefixed renames are glibc per-TU static-inline
dups (byteswap etc.); they vanish once the target mini-libc headers replace
glibc on the preprocess path.

## Findings (both host-header artifacts, neither a CIL-capability problem)

1. **gcc 15 defaults to C23**, whose `true`/`false` keywords leak through
   `doomtype.h`'s C89 fallback and break CIL's (C11) grammar → 79/80 "parse
   failures" on first run (one bad file also poisons the rest via CIL's
   sticky global `Errormsg.hadErrors`, which the driver now resets per
   file). Fix: pin `-std=gnu99` at preprocess — which the real pipeline
   does anyway.
2. **`reallocarray` roundtrip error**: glibc declares it twice, the second
   decl adding a *self-referential* `__malloc__(reallocarray,1)` attribute;
   CIL's merge dedups to one decl, putting the self-reference inside its own
   declarator. Roundtrip strips arg-taking `__malloc__` attrs (a 2-pattern
   sed); irrelevant to the target path (no glibc there).

Also observed: 3 benign warnings (tables.c array-type comparisons,
machine-dependent constant eval), and `p_maputl.c` `InterceptsOverrun`
pointer↔int casts that warn on the LP64 host — a reminder the real pipeline
must run CIL with a **32-bit machdep** (goblint-cil supports custom machine
models; on ILP32 that code is exact).

## 32-bit machdep rerun (`--risc5-machdep`)

The driver now takes `--risc5-machdep`: `Machdep.gcc32` with the two RISC5
pins from SEAM.md §4 (`char_is_unsigned = true`, `little_endian = true`),
installed via `envMachine` before `initCIL`. Confirmed in-process:
`int=4 long=4 ptr=4 char_unsigned=true LE=true`.

- **80/80 parse, merge clean, stats identical** to the host run (same
  1 184 functions, 12 080 instrs, same 10 DOOM-real renames) — no DOOM
  code is machine-model-sensitive at the front-end level.
- Diff of the two merged TUs is exactly the expected shape and nothing
  else: `size_t` prints as `unsigned int`, literal suffixes `UL` → `U`,
  all confined to glibc declarations.
- **Roundtrip `gcc -m32 -std=gnu99 -c`: OK** (host has multilib), giving
  real ILP32 budget numbers for all of doomgeneric at -O0:
  **.text 404 KB, .data 62 KB, .bss 245 KB ≈ 712 KB total** — comfortably
  inside SEAM.md §8's 1.75 MB blob cap, before any of our size work.
- The `InterceptsOverrun` pointer↔int concern from the host run is moot
  under ILP32, as predicted.

## What this buys (per DOOM.md §9, now unlocked)

- Track 1c's "single-TU amalgamation + PureDOOM rename map" → a library
  call, verified here at full scale.
- Backend workload is now measured, not guessed: 12 k CIL instrs (already
  side-effect-free, types resolved, CFG attached) → order 100–200 k RISC5
  instructions — comfortably inside the 1.75 MB blob budget.
- Next step on this branch if adopted: the backend skeleton — CIL instr →
  shared `Risc5_isa.instr` (the emulator's `risc.ml` type) → `encode` —
  with the §7 differential jig (random C snippet: our backend in the
  emulator vs host gcc) from day one.
