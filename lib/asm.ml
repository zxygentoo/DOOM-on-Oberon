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

let load_const2 d n = List.map ins (L.load_const_pair d n)
