(** Per-function compilation (AGENT.md 1b): translate one integer *leaf* function —
    straight-line code, if/while/for control flow, word and unsigned-char memory
    through the s3.2/s3.3a address calculus (globals/statics off DB, array indexing,
    struct fields, deref chains, [&global], array decay, pointer arithmetic, LDB/STB
    for char; offsets resolve through a {!Globals.t}) — from CIL's typed AST to a
    {!Emu.Risc5_isa.instr} list. Naive register allocation
    (ABI §2: a leaf uses R0-R11 freely; args and return sit in R0..). Constructs
    outside the supported subset raise {!Check.Unsupported} rather than miscompile
    (ABI §4 + the spikes/cil census). *)

(** [compile ~globals fd] lowers a leaf function to its instruction list: integer args
    arrive in R0.., the result leaves in R0 (ABI §3a); globals resolve to DB-relative
    offsets through [globals] (default {!Globals.no_globals}: any global access
    refuses). Raises {!Check.Unsupported} on anything outside the supported subset. *)
val compile : ?globals:Globals.t -> GoblintCil.fundec -> Emu.Risc5_isa.instr list
