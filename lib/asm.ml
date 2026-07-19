(* The 1a eDSL prelude: the shared instruction-builder vocabulary every hand-instr
   module (Crt0, Runtime, Drawers, bin/emit_rom) writes its frag streams in. One
   definition so the builders — above all [load_const2], the fixed 2-word constant
   build whose size-independent-of-value discipline the linker's deterministic
   layout depends on (Linker.load_const_pair) — cannot drift per file. *)

module R = Emu.Risc5_isa
module L = Linker

let ins i = L.Ins i
let alu ?(u = false) op a b operand = ins (R.Alu { op; u; v = false; a; b; operand })
let ldw a base off = ins (R.Load { size = R.W; a; base; off })
let ldb a base off = ins (R.Load { size = R.B; a; base; off })
let stw a base off = ins (R.Store { size = R.W; a; base; off })
let mov d s = alu R.Mov d 0 (R.Reg s)
let movi d n = alu R.Mov d 0 (R.Imm n)
let bcc c l = L.Bcc (c, false, l)
let bcc_not c l = L.Bcc (c, true, l)

let ret =
  ins (R.Branch { cond = R.True; neg = false; link = false; target = R.To_reg 15 })
;;

(* the fixed 2-word absolute-constant load ({!Linker.load_const_pair}, as frags) *)
let load_const2 d n = List.map ins (L.load_const_pair d n)
