(** Execute a compiled leaf body in the vendored emulator — the execution half of the
    differential jig (AGENT.md §7). *)

(** [run_leaf body args] loads [body] into emulator RAM, places [args] in R0.., runs until
    control falls off the end of the body (intra-body branches may loop or skip), and returns
    R0 (the ABI §3a return register). Intra-body branches only — no calls; the prologue/
    epilogue and the register-target return branch arrive with the call slice. Raises
    [Failure] if a step cap is exceeded (a mis-resolved branch or non-terminating body). *)
val run_leaf : Emu.Risc5_isa.instr list -> int list -> int
