(** Slice 1 of the RISC5 backend (DOOM.md 1b): translate a straight-line integer *leaf*
    function from CIL's typed AST to a {!Emu.Risc5_isa.instr} list. Naive register
    allocation (SEAM §2: a leaf uses R0-R11 freely; args and return sit in R0..). Constructs
    outside the supported subset raise {!Unsupported} rather than miscompile — the
    pre-codegen gate (SEAM §4 + the spikes/cil census). *)

(** Raised for any construct slice 1 does not handle: float / 64-bit / bitfield (banned
    outright, SEAM §4), and control flow / calls / memory / [/] / unsigned [>>] (deferred).
    The message names the slice responsible for it. *)
exception Unsupported of string

(** [compile_fundec fd] lowers a leaf function to its instruction list: integer args arrive
    in R0.., the result leaves in R0 (SEAM §3a). Raises {!Unsupported} on anything outside
    the slice-1 subset. *)
val compile_fundec : GoblintCil.fundec -> Emu.Risc5_isa.instr list
