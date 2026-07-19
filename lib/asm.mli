(** The 1a eDSL prelude: thin builders over {!Linker.frag} / {!Emu.Risc5_isa.instr},
    the shared vocabulary of every hand-instr module ({!Crt0}, {!Runtime},
    {!Drawers}, bin/emit_rom). The bodies stay hand-scheduled per module; only the
    constructors live here, so the encoding idioms — above all [load_const2]'s
    fixed 2-word discipline — have a single definition. *)

val ins : Emu.Risc5_isa.instr -> Linker.frag

val alu
  :  ?u:bool
  -> Emu.Risc5_isa.op
  -> Emu.Risc5_isa.reg
  -> Emu.Risc5_isa.reg
  -> Emu.Risc5_isa.operand
  -> Linker.frag

val ldw : Emu.Risc5_isa.reg -> Emu.Risc5_isa.reg -> int -> Linker.frag
val ldb : Emu.Risc5_isa.reg -> Emu.Risc5_isa.reg -> int -> Linker.frag
val stw : Emu.Risc5_isa.reg -> Emu.Risc5_isa.reg -> int -> Linker.frag

(** [mov d s]: R[d] <- R[s]; [movi d n]: R[d] <- 16-bit immediate [n]. *)
val mov : Emu.Risc5_isa.reg -> Emu.Risc5_isa.reg -> Linker.frag

val movi : Emu.Risc5_isa.reg -> int -> Linker.frag

(** Conditional branch to label [l] on [c] holding / not holding. *)
val bcc : Emu.Risc5_isa.cond -> int -> Linker.frag

val bcc_not : Emu.Risc5_isa.cond -> int -> Linker.frag

(** [B LNK] — the frame-less leaf return. *)
val ret : Linker.frag

(** The fixed 2-word absolute-constant load ({!Linker.load_const_pair} as frags):
    ALWAYS two words, even for a zero high half — a hand stream's size must not
    depend on values that exist only after layout. *)
val load_const2 : Emu.Risc5_isa.reg -> int -> Linker.frag list
