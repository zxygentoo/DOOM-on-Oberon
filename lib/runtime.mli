(** The runtime helpers (ABI §5): hand-rolled [Risc5_isa] instruction sequences the
    backend calls by name — the first drawer of the 1a eDSL, where hand-written and
    compiled code meet as the same kind of value ({!Linker.obj}) and link freely into
    one program.

    The division family: [__div]/[__mod] (signed, C-truncating) and
    [__udiv]/[__umod] (unsigned), plus [__lsr] (variable-count logical shift —
    RISC5 has no LSR, so ROR + a runtime mask). All are standard ABI calls — args
    in R0/R1, result in R0, caller-saved (R0-R5 + H + flags) clobbered,
    callee-saved and SP untouched; each is a frame-less leaf returning via [B LNK].

    And the exit escape (ABI §7): [__setjmp]/[__longjmp] over a nine-word jmp_buf
    (R6-R12, SP, LNK — the callee-saved state; DB is crt0-constant). [__setjmp]
    clobbers only R0; [__longjmp] never returns to its caller. *)

(** Every helper, ready to append to a program's object list before {!Linker.link}. *)
val objs : Linker.obj list
