# Third-party material

What in this repository comes from elsewhere, where it came from, and the terms it
carries. Everything not listed here is this project's own work under the MIT license in
[`LICENSE`](LICENSE).

| Path | What it is | Upstream | Terms |
| --- | --- | --- | --- |
| `vendor/doomgeneric` | DOOM, reduced to doomgeneric's six platform hooks — a git submodule | [`ozkl/doomgeneric`][dg] at `dcb7a8d` | GPL-2.0-or-later (its `LICENSE`; © 1993-1996 id Software, 2005-2014 Simon Howard) |
| `patch/c/*.patch` | The port's changes to doomgeneric's sources | — | GPL-2.0-or-later, as the files they change |
| `lib/drawers.ml` (`R_DrawSpan`, `R_DrawColumn`), `libc/fixed.c` | Hand translations of doomgeneric's `r_draw.c` drawers and of `m_fixed.c`'s `FixedDiv` | doomgeneric | GPL-2.0-or-later |
| `test/test_jig.ml` | Quotes a few doomgeneric functions as test inputs: the `r_draw.c` drawers and `m_fixed.c`'s `int64_t` originals | doomgeneric | GPL-2.0-or-later, for the quoted code |
| `patch/oberon/Input.Mod.patch` | A change to Project Oberon 2013's `Input.Mod` | Project Oberon 2013, by way of the emulator's disk image | [notice A](#a-project-oberon-2013) |
| `vendor/oberon-risc-hardcaml` | The machine (the Hardcaml design, its board layer and Oberon drivers) and, nested in it, the OCaml emulator with its disk image and tools — a git submodule | [`zxygentoo/oberon-risc-hardcaml`][hc] `v0.1.0` | its own `LICENSE` (MIT) and `THIRD_PARTY.md`; the emulator's are ISC |

Not vendored: the DOOM shareware IWAD. `make wad` downloads `doom1.wad` (v1.9) and
checks it against the md5 pinned in the `Makefile`; [notice B](#b-the-doom-shareware-iwad).

## What the built artifacts contain

- **`doom.blob`** is doomgeneric compiled by this repository's compiler, linked with its
  libc, runtime and drawers: as a whole, GPL-2.0-or-later. Its corresponding source is
  this repository at the same commit, with `vendor/doomgeneric` at its pin.
- **`DOOM.dsk`** is an aggregate disk image: the Project Oberon 2013 system from the
  emulator's `Oberon-2020-08-18.dsk` with `Oberon.Mod` and `Input.Mod` patched
  ([notice A](#a-project-oberon-2013)); the emulator's serial agent, `AgentTool` and
  `AgentProtocol` (ISC); the host's `Halftone.Mod` and `Mandel.Mod` (MIT); `DOOM.Mod`
  (this project, MIT); `doom.blob` (GPL-2.0-or-later); and the shareware IWAD, its bytes
  unmodified, split into `doom1.wad.0` and `doom1.wad.1`, which `DOOM.Mod` concatenates
  back ([notice B](#b-the-doom-shareware-iwad)).

## Notices

### A. Project Oberon 2013

```
Project Oberon, Revised Edition 2013

Book copyright (C)2013 Niklaus Wirth and Juerg Gutknecht;
software copyright (C)2013 Niklaus Wirth (NW), Juerg Gutknecht (JG), Paul
Reed (PR/PDR).

Permission to use, copy, modify, and/or distribute this software and its
accompanying documentation (the "Software") for any purpose with or
without fee is hereby granted, provided that the above copyright notice
and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHORS DISCLAIM ALL WARRANTIES
WITH REGARD TO THE SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY, FITNESS AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS BE LIABLE FOR ANY CLAIM, SPECIAL, DIRECT, INDIRECT, OR
CONSEQUENTIAL DAMAGES OR ANY DAMAGES OR LIABILITY WHATSOEVER, WHETHER IN
AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE DEALINGS IN OR USE OR PERFORMANCE OF THE SOFTWARE.
```

### B. The DOOM shareware IWAD

`doom1.wad`, the shareware episode of DOOM, is © 1994 id Software. Its "Limited Use
Software License Agreement" lets a user "make copies of the Software to give to other
persons", and bars modifying it or making derivative works of it. On distribution, John
Carmack of id Software wrote on 23 October 1999: "The DOOM shareware wad is freely
distributable." Both are reproduced in Debian's [`doom-wad-shareware` copyright
file][deb], from which they are quoted here.

[dg]: https://github.com/ozkl/doomgeneric
[hc]: https://github.com/zxygentoo/oberon-risc-hardcaml
[deb]: https://tracker.debian.org/media/packages/d/doom-wad-shareware/copyright-1.9.fixed-4
