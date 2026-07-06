(** The runtime helpers (ABI §5): hand-rolled [Risc5_isa] instruction sequences the
    backend calls by name — the first drawer of the 1a eDSL, where hand-written and
    compiled code meet as the same kind of value ({!Linker.obj}) and link freely into
    one program.

    Currently the division family: [__div]/[__mod] (signed, C-truncating) and
    [__udiv]/[__umod] (unsigned). All four are standard ABI calls — args in R0/R1,
    result in R0, caller-saved (R0-R5 + H + flags) clobbered, callee-saved and SP
    untouched; each is a frame-less leaf returning via [B LNK]. *)

(** Every helper, ready to append to a program's object list before {!Linker.link}. *)
val objs : Linker.obj list
