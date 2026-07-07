(* The runtime helpers (ABI §5), hand-rolled over risc5_isa — the 1a eDSL's first
   drawer. The division family bridges the two DIV gaps (AGENT.md §4):

   - Semantics: C99 mandates truncation toward zero (-7/2 = -3, remainder takes the
     dividend's sign); RISC5 DIV is *floored* (-7/2 = -4, H = remainder in [0, divisor)).
     The two agree unless the signs differ AND the division is inexact — then
     trunc = floor + 1 and the C remainder is H - divisor.
   - Envelope: the hardware divider sign-handles only the *dividend*; the divisor must
     be in [1, 2^31-1] (divider.ml's own qcheck encodes it — outside it the RTL's
     shift-subtract loop returns garbage, not floored results). So a negative divisor
     is negated first and the quotient's sign fixed after; INT_MIN (un-negatable:
     -INT_MIN wraps to itself) and 0 (C UB; we return 0 deterministically rather than
     trust the divider) get their own branches. No helper ever issues an
     out-of-envelope DIV.
   - Unsigned: DIV' (the u-variant) divides *unsigned* exactly for any 32-bit dividend,
     same divisor envelope — so __udiv/__umod need only the divisor-top-bit-set case
     (quotient is 0 or 1 by one unsigned compare, ABI §5's "slow path") on top of a
     single DIV'.

   Contract (ABI §5): standard calls — a = R0, b = R1, result R0; caller-saved
   (R0-R5 + H + flags) clobbered (these bodies touch only R0-R3 + H); callee-saved,
   SP, LNK-discipline all standard; frame-less leaves, return via B LNK. Every
   register-writing ALU op sets N/Z from its result (Mov included), which is what the
   Bcc's after each Mov read. *)

module R = Emu.Risc5_isa
module L = Linker

let ins i = L.Ins i
let alu ?(u = false) op a b operand = ins (R.Alu { op; u; v = false; a; b; operand })
let bcc cond l = L.Bcc (cond, false, l)
let bcc_not cond l = L.Bcc (cond, true, l)

let ret =
  ins (R.Branch { cond = R.True; neg = false; link = false; target = R.To_reg 15 })
;;

(* R[d] <- H (Mov u, register form, v=0) — the divider's remainder / MUL's high word. *)
let mov_h d = alu ~u:true R.Mov d 0 (R.Reg 0)

(* R[d] <- 0x80000000 = INT_MIN (Mov u, immediate form: the 16-bit field lands high). *)
let mov_int_min d = alu ~u:true R.Mov d 0 (R.Imm 0x8000)

(* __div: R0 = trunc(R0 / R1). Branch on the divisor's sign, then the dividend's; the
   b > 0 paths use the hardware's own floored handling of a negative dividend and fix
   floor -> trunc by +1 when the remainder is nonzero; the b < 0 paths divide by -b and
   negate the quotient (trunc is sign-symmetric; floor is not — which is why the fix
   happens before the negate). *)
let div_obj : L.obj =
  let l_bneg = 0
  and l_aneg = 1
  and l_q_out = 2
  and l_negneg = 3
  and l_nq_out = 4
  and l_bmin = 5
  and l_one = 6
  and l_zero = 7 in
  { L.name = "__div"
  ; frags =
      [ alu R.Mov 2 0 (R.Reg 1) (* flags <- b *)
      ; bcc R.Eq l_zero (* b = 0: UB -> 0 *)
      ; bcc R.Mi l_bneg
      ; (* b > 0 *)
        alu R.Mov 2 0 (R.Reg 0) (* flags <- a *)
      ; bcc R.Mi l_aneg
      ; alu R.Div 0 0 (R.Reg 1) (* a >= 0, b > 0: floored = truncated *)
      ; ret
      ; L.Label l_aneg (* a < 0, b > 0: trunc = floor + (r <> 0) *)
      ; alu R.Div 2 0 (R.Reg 1) (* R2 = floor(a/b), H = r in [0, b) *)
      ; mov_h 3 (* flags <- r *)
      ; bcc R.Eq l_q_out
      ; alu R.Add 2 2 (R.Imm 1)
      ; L.Label l_q_out
      ; alu R.Mov 0 0 (R.Reg 2)
      ; ret
      ; L.Label l_bneg
      ; mov_int_min 3
      ; alu R.Sub 3 1 (R.Reg 3) (* Z iff b = INT_MIN (un-negatable) *)
      ; bcc R.Eq l_bmin
      ; alu R.Mov 3 0 (R.Imm 0)
      ; alu R.Sub 3 3 (R.Reg 1) (* R3 = -b in [1, 2^31-1] *)
      ; alu R.Mov 2 0 (R.Reg 0) (* flags <- a *)
      ; bcc R.Mi l_negneg
      ; alu R.Div 2 0 (R.Reg 3) (* a >= 0: trunc(a/|b|) directly *)
      ; alu R.Mov 0 0 (R.Imm 0)
      ; alu R.Sub 0 0 (R.Reg 2) (* negate: trunc(a/b) *)
      ; ret
      ; L.Label l_negneg (* a < 0, b < 0 *)
      ; alu R.Div 2 0 (R.Reg 3) (* floor(a/|b|), H = r *)
      ; mov_h 3 (* flags <- r *)
      ; bcc R.Eq l_nq_out
      ; alu R.Add 2 2 (R.Imm 1) (* trunc(a/|b|) *)
      ; L.Label l_nq_out
      ; alu R.Mov 0 0 (R.Imm 0)
      ; alu R.Sub 0 0 (R.Reg 2) (* negate: positive quotient *)
      ; ret
      ; L.Label l_bmin (* b = INT_MIN: q = (a = INT_MIN) ? 1 : 0 *)
      ; mov_int_min 3
      ; alu R.Sub 3 0 (R.Reg 3)
      ; bcc R.Eq l_one
      ; L.Label l_zero
      ; alu R.Mov 0 0 (R.Imm 0)
      ; ret
      ; L.Label l_one
      ; alu R.Mov 0 0 (R.Imm 1)
      ; ret
      ]
  }
;;

(* __mod: R0 = R0 % R1, C semantics — the remainder takes the *dividend's* sign and
   pairs with __div so (a/b)*b + a%b = a. Key identity: a % b = a % |b| for any b sign
   (substitute b = -|b| into a - trunc(a/b)*b and the two negations cancel), so one
   |b| staging serves both divisor signs; then H is the answer for a >= 0, and
   H - |b| (when H <> 0) for a < 0. *)
let mod_obj : L.obj =
  let l_go = 0
  and l_aneg = 1
  and l_ret = 2
  and l_bmin = 3
  and l_zero = 4 in
  { L.name = "__mod"
  ; frags =
      [ alu R.Mov 2 0 (R.Reg 1) (* R2 = b, flags <- b *)
      ; bcc R.Eq l_zero (* b = 0: UB -> 0 *)
      ; bcc_not R.Mi l_go (* b > 0: R2 already |b| *)
      ; mov_int_min 2
      ; alu R.Sub 2 1 (R.Reg 2) (* Z iff b = INT_MIN *)
      ; bcc R.Eq l_bmin
      ; alu R.Mov 2 0 (R.Imm 0)
      ; alu R.Sub 2 2 (R.Reg 1) (* R2 = -b = |b| *)
      ; L.Label l_go (* R2 = |b| in [1, 2^31-1] *)
      ; alu R.Mov 3 0 (R.Reg 0) (* flags <- a *)
      ; bcc R.Mi l_aneg
      ; alu R.Div 3 0 (R.Reg 2) (* a >= 0: H = r >= 0 is the C result *)
      ; mov_h 0
      ; ret
      ; L.Label l_aneg
      ; alu R.Div 3 0 (R.Reg 2) (* floored: H = r in [0, |b|) *)
      ; mov_h 0 (* flags <- r *)
      ; bcc R.Eq l_ret (* exact: r = 0 *)
      ; alu R.Sub 0 0 (R.Reg 2) (* r - |b| in (-|b|, 0): the dividend's sign *)
      ; L.Label l_ret
      ; ret
      ; L.Label l_bmin (* b = INT_MIN: a % b = a, except a = INT_MIN -> 0 *)
      ; mov_int_min 2
      ; alu R.Sub 2 0 (R.Reg 2) (* Z iff a = INT_MIN *)
      ; bcc R.Eq l_zero
      ; ret (* R0 = a, untouched *)
      ; L.Label l_zero
      ; alu R.Mov 0 0 (R.Imm 0)
      ; ret
      ]
  }
;;

(* __udiv: R0 = R0 /u R1. DIV' (u = 1) divides unsigned exactly for ANY 32-bit dividend
   as long as the divisor is in [1, 2^31-1] — one instruction covers everything except
   a top-bit-set divisor, where the quotient can only be 0 or 1 (a < 2*b always), decided
   by one unsigned compare (after SUB, C is set iff a <u b — the s5.2 carry convention). *)
let udiv_obj : L.obj =
  let l_bbig = 0
  and l_zero = 1 in
  { L.name = "__udiv"
  ; frags =
      [ alu R.Mov 2 0 (R.Reg 1) (* flags <- b *)
      ; bcc R.Eq l_zero (* b = 0: UB -> 0 *)
      ; bcc R.Mi l_bbig (* N = top bit = b >=u 2^31 *)
      ; alu ~u:true R.Div 0 0 (R.Reg 1) (* DIV': exact unsigned *)
      ; ret
      ; L.Label l_bbig (* q = (a >=u b) ? 1 : 0 *)
      ; alu R.Sub 2 0 (R.Reg 1) (* C iff a <u b *)
      ; bcc R.Cs l_zero
      ; alu R.Mov 0 0 (R.Imm 1)
      ; ret
      ; L.Label l_zero
      ; alu R.Mov 0 0 (R.Imm 0)
      ; ret
      ]
  }
;;

(* __umod: R0 = R0 %u R1 — same split as __udiv: DIV' then read H, or for a
   top-bit-set divisor r = a - b when a >=u b (that difference is already in the
   compare's destination), else a itself. *)
let umod_obj : L.obj =
  let l_bbig = 0
  and l_ret = 1
  and l_zero = 2 in
  { L.name = "__umod"
  ; frags =
      [ alu R.Mov 2 0 (R.Reg 1) (* flags <- b *)
      ; bcc R.Eq l_zero (* b = 0: UB -> 0 *)
      ; bcc R.Mi l_bbig
      ; alu ~u:true R.Div 2 0 (R.Reg 1) (* DIV': H = a mod b *)
      ; mov_h 0
      ; ret
      ; L.Label l_bbig (* r = (a >=u b) ? a - b : a *)
      ; alu R.Sub 2 0 (R.Reg 1) (* R2 = a - b; C iff a <u b *)
      ; bcc R.Cs l_ret (* a < b: r = a, untouched in R0 *)
      ; alu R.Mov 0 0 (R.Reg 2)
      ; L.Label l_ret
      ; ret
      ; L.Label l_zero
      ; alu R.Mov 0 0 (R.Imm 0)
      ; ret
      ]
  }
;;

let stw a base off = ins (R.Store { size = R.W; a; base; off })
let ldw a base off = ins (R.Load { size = R.W; a; base; off })

(* __setjmp / __longjmp — the exit escape (ABI §7: exit/I_Error return through
   the thunk, never halt). A jmp_buf on this ABI is exactly the callee-saved
   state: R6-R11 (the homes), R12 (FP), R14 (SP), R15 (LNK) — nine words at the
   buffer in R0. DB (R13) has no slot: crt0 sets it once and nothing ever writes
   it. __longjmp's "second return" is just the reload: the restored LNK IS the
   __setjmp call site, so B LNK lands there with R0 = val — and the entry
   function's own epilogue then unwinds normally from its untouched frame (SP
   came back with the buffer). The caller guarantees val <> 0 (exit passes 1).
   Under naive allocation this is C-clean, not just classically clean: every
   live-across-call local sits in a home register, so a longjmp restores locals
   to their setjmp-time values — the shape C's semantics permit. *)
let jmp_buf_regs = [ 6; 7; 8; 9; 10; 11; 12; 14; 15 ]

let setjmp_obj : L.obj =
  { L.name = "__setjmp"
  ; frags =
      List.mapi (fun i r -> stw r 0 (4 * i)) jmp_buf_regs
      @ [ alu R.Mov 0 0 (R.Imm 0); ret ]
  }
;;

let longjmp_obj : L.obj =
  { L.name = "__longjmp"
  ; frags =
      List.mapi (fun i r -> ldw r 0 (4 * i)) jmp_buf_regs
      @ [ alu R.Mov 0 0 (R.Reg 1); ret (* ret = B LNK: the restored R15 *) ]
  }
;;

let objs = [ div_obj; mod_obj; udiv_obj; umod_obj; setjmp_obj; longjmp_obj ]
