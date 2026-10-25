(** Per-function code generation: one CIL function to its unresolved {!Linker.obj}.

    The output is a well-formed ABI §3 callee: args arrive in R0-R3 (5+ on the stack),
    the result leaves in R0, the callee-saved registers it writes are saved and
    restored, and it returns via [B LNK]. Globals resolve to DB-relative offsets
    through [globals]; calls, function addresses and the runtime helpers stay symbolic
    for {!Linker.link}.

    Allocation is naive: every register-eligible variable keeps one home register for
    the whole function, so control-flow merges need no reconciliation. Variables past
    the six homes, aggregates and address-taken scalars live in SP-relative frame
    slots. A statement needing more scratch registers than the pool holds triggers one
    retry over a three-address rewrite of the function.

    Anything the backend can't lower correctly raises {!Check.Unsupported}; a broken
    backend invariant raises {!Check.Internal}. *)
val compile : globals:Globals.t -> GoblintCil.fundec -> Linker.obj
