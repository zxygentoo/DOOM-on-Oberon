(* The division family bridges two gaps between C and the hardware divider:

   - Semantics: C truncates toward zero (-7/2 = -3, the remainder takes the dividend's
     sign); RISC5 DIV floors (-7/2 = -4, H = remainder in [0, divisor)). They agree
     unless the signs differ and the division is inexact — then trunc = floor + 1 and
     the C remainder is H - divisor.
   - Envelope: the divider sign-handles only the dividend; the divisor must be in
     [1, 2^31-1], and outside it the result is garbage, not floored. So a negative
     divisor is negated first and the quotient's sign fixed after; INT_MIN (which
     can't be negated) and 0 (C UB; we return 0 rather than trust the divider) get
     their own branches. No helper issues an out-of-envelope DIV.
   - Unsigned: DIV' (u = 1) divides unsigned exactly for any dividend, same divisor
     envelope, so __udiv/__umod add only the top-bit-set divisor case.

   Every register-writing ALU op sets N/Z from its result, MOV included — that is what
   the Bcc after each "flags <-" MOV reads. *)

module R = Emu.Risc5_isa
module L = Linker
open Asm

(* R[d] <- H: MOV' register form — the divider's remainder, MUL's high word *)
let mov_h d = alu ~u:true R.Mov d 0 (R.Reg 0)

(* R[d] <- INT_MIN: MOV' immediate form, the 16-bit field lands high *)
let mov_int_min d = alu ~u:true R.Mov d 0 (R.Imm 0x8000)

(* __div: the b > 0 paths use the hardware's floored handling of a negative dividend
   and fix floor -> trunc by +1 when the remainder is nonzero; the b < 0 paths divide
   by -b and negate (trunc is sign-symmetric, floor is not — so the fix comes before
   the negate). *)
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

(* __mod: a % b = a % |b| for either sign of b (substitute b = -|b| into
   a - trunc(a/b)*b and the negations cancel), so one |b| serves both; then H is the
   answer for a >= 0, and H - |b| (when H <> 0) for a < 0. *)
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

(* __udiv: one DIV' unless the divisor's top bit is set — then the quotient is 0 or 1
   (a < 2b always), decided by one compare: after SUB, C is set iff a <u b. *)
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

(* __umod: DIV' then H; for a top-bit-set divisor, r = a - b when a >=u b (already in
   the compare's destination), else a. *)
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

(* exit/I_Error unwind to the entry thunk through these (ABI §7). A jmp_buf is the
   callee-saved state; DB has no slot (crt0 sets it once). __longjmp's "second return"
   is just the reload: the restored LNK is the __setjmp call site, and SP comes back
   with it. The caller guarantees val <> 0.
   Correct for C locals only because the allocator keeps every value live across a
   call in a callee-saved home, so a longjmp restores locals to their setjmp-time
   values — an allocator that caches values elsewhere would break this. *)
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
      @ [ alu R.Mov 0 0 (R.Reg 1); ret (* B LNK: the restored R15 *) ]
  }
;;

(* __lsr: ROR by n (the n low bits wrap to the top), then mask them off with
   (1 << (32 - n)) - 1. n = 0 would shift the mask by 32, so it returns early. Counts
   >= 32 are C UB; register-count shifts alias mod 32. *)
let lsr_obj : L.obj =
  let l_ret = 0 in
  { L.name = "__lsr"
  ; frags =
      [ alu R.Mov 2 0 (R.Reg 1) (* flags <- n *)
      ; bcc R.Eq l_ret (* n = 0: x >> 0 = x *)
      ; alu R.Ror 0 0 (R.Reg 1) (* bits [n..31] land at [0..31-n]; n junk bits on top *)
      ; alu R.Mov 2 0 (R.Imm 32)
      ; alu R.Sub 2 2 (R.Reg 1) (* 32 - n in [1, 31] *)
      ; alu R.Mov 3 0 (R.Imm 1)
      ; alu R.Lsl 3 3 (R.Reg 2)
      ; alu R.Sub 3 3 (R.Imm 1) (* mask = 2^(32-n) - 1 *)
      ; alu R.And 0 0 (R.Reg 3)
      ; L.Label l_ret
      ; ret
      ]
  }
;;

let objs = [ div_obj; mod_obj; udiv_obj; umod_obj; lsr_obj; setjmp_obj; longjmp_obj ]
