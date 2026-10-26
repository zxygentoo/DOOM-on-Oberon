(lang dune 3.0)

(name doom-on-oberon)

(generate_opam_files true)

(license "MIT AND GPL-2.0-or-later")

(source
 (github zxygentoo/DOOM-on-Oberon))

(maintainers "zxy <zxygentoo@gmail.com>")

(authors "zxy <zxygentoo@gmail.com>")

; The default-switch toolchain, as the generated doom-on-oberon.opam:
; `opam install --deps-only .` on the default switch. Nothing installs — the
; outputs are files under _out/. What opam can't express (gcc -m32 multilib,
; SDL2 for the ref build, initialised submodules, the OxCaml switch for sim/)
; is checked by `make prereqs`.

(package
 (name doom-on-oberon)
 (allow_empty)
 (synopsis
  "DOOM as an Oberon command on Wirth's RISC5 machine, via an all-OCaml C toolchain")
 (description
  "A goblint-cil front end and a RISC5 backend compile doomgeneric into a flat\nblob that a small Oberon-07 stub loads into himem and runs, on the emulator,\nthe cycle-accurate Hardcaml model and a Nexys 4 FPGA.")
 (depends
  (ocaml
   (>= 5.3))
  ; the C front end; every artifact md5 was built with exactly this version
  (goblint-cil
   (= 2.1.0))
  ; the vendored emulator's host tools (make dsk) embed their assets with it
  crunch))
