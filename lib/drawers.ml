(* The 1a hot-loop drawer. See drawers.mli; the dither algorithm spec is
   libc/dither.c's __dg_dither, which stays the oracle on both flanks (gcc in the
   jig, glibc-built host golden) — this is that C, register-scheduled by hand.

   void __dg_dither(const u8 *src, int w, int h, u32 *dst, int stride)
     args: R0=src  R1=w  R2=h  R3=dst  stride at [entry SP + 16] (ABI §3, arg 5)

   Register plan (leaf; R6-R11 + LNK saved to the frame):
     R0 src cursor (advances linearly through all w*h bytes)
     R1 the constant 0 (ADD' carry pickup) — w parks in a frame slot first
     R2 rows remaining          R3 dst row cursor (byte address)
     R4 stride*4 (byte stride; negative on the machine — wraps correctly)
     R5 DB+lum_off              R6 DB+bn_off
     R7 chunks remaining in row R8 out cursor   R9 out2 = out + stride4
     R10 bits                   R11 thr cursor
     R12, R15 pixel temps (R12 blob-internal; LNK restored from frame at exit)
   Frame (SUB SP,44): +0 row_thr  +4 y63  +8 w  +12..36 R6..R11  +40 LNK
     (stride, arg 5, sits at [SP+60] = entry SP + 16.)

   The pixel step, k = 15 downto 0 (descending so LSL-by-2 composes the pairs in
   bit order — pixel 0 lands at bits 1:0, the Oberon leftmost convention):
     LDB R12,[R0+k]      source palette index
     ADD R12,R5,R12      &__dg_lum[s]
     LDB R12,[R12]       lum
     LDB R15,[R11+k]     thr
     SUB R15,R15,R12     C = (thr < lum) unsigned = lum > thr (strict, as C's >)
     ADD' R15,R1,R1      R15 = 0+0+C (the s5.2 carry convention, materialized)
     LSL R12,R15,1 ; IOR R12,R12,R15     R12 = 3*C (the doubled pixel pair)
     LSL R10,R10,2 ; IOR R10,R10,R12
   9 instrs/px; the SUB->ADD' pair is adjacent, so no intervening op disturbs C
   (shifts/IOR set only N/Z; the ADD' itself re-sets C after the read). *)

module R = Emu.Risc5_isa
module L = Linker

let ins i = L.Ins i
let alu ?(u = false) op a b operand = ins (R.Alu { op; u; v = false; a; b; operand })
let ldw a base off = ins (R.Load { size = R.W; a; base; off })
let ldb a base off = ins (R.Load { size = R.B; a; base; off })
let stw a base off = ins (R.Store { size = R.W; a; base; off })
let mov d s = alu R.Mov d 0 (R.Reg s)
let movi d n = alu R.Mov d 0 (R.Imm n)

(* the fixed 2-word constant build (Crt0's discipline: size independent of value) *)
let load_const2 d n =
  [ alu ~u:true R.Mov d 0 (R.Imm ((n lsr 16) land 0xFFFF))
  ; alu R.Ior d d (R.Imm (n land 0xFFFF))
  ]
;;

let ret =
  ins (R.Branch { cond = R.True; neg = false; link = false; target = R.To_reg 15 })
;;

let dither ~lum_off ~bn_off : L.obj =
  let l_row = 0
  and l_chunk = 1
  and l_nowrap = 2
  and l_exit = 3 in
  let pixel k =
    [ ldb 12 0 k
    ; alu R.Add 12 5 (R.Reg 12)
    ; ldb 12 12 0
    ; ldb 15 11 k
    ; alu R.Sub 15 15 (R.Reg 12)
    ; alu ~u:true R.Add 15 1 (R.Reg 1)
    ; alu R.Lsl 12 15 (R.Imm 1)
    ; alu R.Ior 12 12 (R.Reg 15)
    ; alu R.Lsl 10 10 (R.Imm 2)
    ; alu R.Ior 10 10 (R.Reg 12)
    ]
  in
  let pixels =
    List.concat_map pixel [ 15; 14; 13; 12; 11; 10; 9; 8; 7; 6; 5; 4; 3; 2; 1; 0 ]
  in
  { L.name = "__dg_dither"
  ; frags =
      [ alu R.Sub 14 14 (R.Imm 44) (* frame *)
      ; stw 6 14 12
      ; stw 7 14 16
      ; stw 8 14 20
      ; stw 9 14 24
      ; stw 10 14 28
      ; stw 11 14 32
      ; stw 15 14 40
      ; stw 1 14 8 (* w -> slot *)
      ; movi 1 0 (* R1 = the zero register *)
      ; stw 1 14 4 (* y63 = 0 *)
      ; ldw 4 14 60 (* stride (entry SP + 16) *)
      ; alu R.Lsl 4 4 (R.Imm 2) (* stride4 *)
      ]
      @ load_const2 5 lum_off
      @ [ alu R.Add 5 13 (R.Reg 5) (* R5 = DB + lum_off *) ]
      @ load_const2 6 bn_off
      @ [ alu R.Add 6 13 (R.Reg 6) (* R6 = DB + bn_off *)
        ; alu R.Sub 12 2 (R.Imm 0) (* h == 0? *)
        ; L.Bcc (R.Eq, false, l_exit)
        ; L.Label l_row
        ; (* row_thr = bn + (y63 << 6); thr = row_thr; y63 = (y63+1) & 63 *)
          ldw 12 14 4
        ; alu R.Lsl 15 12 (R.Imm 6)
        ; alu R.Add 15 6 (R.Reg 15)
        ; stw 15 14 0
        ; mov 11 15
        ; alu R.Add 12 12 (R.Imm 1)
        ; alu R.And 12 12 (R.Imm 63)
        ; stw 12 14 4
        ; ldw 12 14 8 (* chunks = w >> 4 *)
        ; alu R.Asr 7 12 (R.Imm 4)
        ; mov 8 3 (* out = dst row *)
        ; alu R.Add 9 8 (R.Reg 4) (* out2 = out + stride4 *)
        ; alu R.Add 3 3 (R.Reg 4) (* dst row += 2*stride4 *)
        ; alu R.Add 3 3 (R.Reg 4)
        ; L.Label l_chunk
        ; movi 10 0
        ]
      @ pixels
      @ [ stw 10 8 0 (* the 2x2 doubling: same word, both lines *)
        ; stw 10 9 0
        ; alu R.Add 8 8 (R.Imm 4)
        ; alu R.Add 9 9 (R.Imm 4)
        ; alu R.Add 0 0 (R.Imm 16) (* src += 16 *)
        ; alu R.Add 11 11 (R.Imm 16) (* thr += 16, wrap at row_thr + 64 *)
        ; ldw 12 14 0
        ; alu R.Sub 15 11 (R.Reg 12)
        ; alu R.Sub 15 15 (R.Imm 64)
        ; L.Bcc (R.Eq, true, l_nowrap)
        ; mov 11 12
        ; L.Label l_nowrap
        ; alu R.Sub 7 7 (R.Imm 1)
        ; L.Bcc (R.Eq, true, l_chunk)
        ; alu R.Sub 2 2 (R.Imm 1)
        ; L.Bcc (R.Eq, true, l_row)
        ; L.Label l_exit
        ; ldw 6 14 12
        ; ldw 7 14 16
        ; ldw 8 14 20
        ; ldw 9 14 24
        ; ldw 10 14 28
        ; ldw 11 14 32
        ; ldw 15 14 40
        ; alu R.Add 14 14 (R.Imm 44)
        ; ret
        ]
  }
;;
