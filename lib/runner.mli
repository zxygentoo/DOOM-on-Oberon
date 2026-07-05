(** Execute a compiled leaf body in the vendored emulator — the execution half of the
    differential jig (AGENT.md §7). *)

(** [run_leaf body args] loads the straight-line [body] into emulator RAM, places [args] in
    R0.., single-steps once per instruction, and returns R0 (the ABI §3a return register).
    Straight-line only: no branches or calls — prologue/epilogue and the return branch
    arrive with the call slice. *)
val run_leaf : Emu.Risc5_isa.instr list -> int list -> int
