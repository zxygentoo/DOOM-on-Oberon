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
open Asm

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

(* ---- R_DrawSpan / R_DrawColumn (drawers #2/#3) ----------------------------------
   The r_draw.c bodies (RANGECHECK included — it is compiled into the shipped .i),
   register-scheduled. Both share the shape: load the ds_*/dc_* state once into
   registers (the C already hoists what it can; the remaining tax was pure naive
   expression codegen), then a tight do-while. Logical >> is ROR+mask (s5.2b);
   signed >> is ASR; the unsigned compares read C after SUB (s5.2). Loops run
   count+1 iterations (C's post-decrement while (count--)).

   Frame: SUB SP,36 — [0..15] the ABI §3 outgoing home area (live during the
   RANGECHECK I_Error call), [16] R6, [20] R7, [24] LNK. I_Error never returns
   (the port's setjmp-shaped exit), but the error block still parks after the BL. *)

let bl_sym name = L.Call name
let ldw_db a off = ldw a 13 off

let span ~off ~str : L.obj =
  let ds_y = off "ds_y"
  and ds_x1 = off "ds_x1"
  and ds_x2 = off "ds_x2"
  and ds_colormap = off "ds_colormap"
  and ds_source = off "ds_source"
  and ds_xfrac = off "ds_xfrac"
  and ds_yfrac = off "ds_yfrac"
  and ds_xstep = off "ds_xstep"
  and ds_ystep = off "ds_ystep"
  and ylookup = off "ylookup"
  and columnofs = off "columnofs"
  and fmt = str "R_DrawSpan: %i to %i at %i" in
  let l_loop = 0
  and l_err = 1
  and l_park = 2 in
  { L.name = "R_DrawSpan"
  ; frags =
      [ alu R.Sub 14 14 (R.Imm 36)
      ; stw 6 14 16
      ; stw 7 14 20
      ; stw 15 14 24 (* RANGECHECK (compiled into the shipped .i) *)
      ; ldw_db 0 ds_x2
      ; ldw_db 1 ds_x1
      ; alu R.Sub 2 0 (R.Reg 1) (* count = ds_x2 - ds_x1 *)
      ; bcc R.Lt l_err (* ds_x2 < ds_x1 *)
      ; alu R.Sub 3 1 (R.Imm 0)
      ; bcc R.Lt l_err (* ds_x1 < 0 *)
      ; alu R.Sub 3 0 (R.Imm 320)
      ; bcc_not R.Lt l_err (* ds_x2 >= 320 (nonneg here: signed ok) *)
      ; ldw_db 3 ds_y
      ; movi 0 200
      ; alu R.Sub 0 0 (R.Reg 3)
      ; bcc R.Cs l_err (* C: 200 < ds_y unsigned = (unsigned)ds_y > 200 *)
      ; alu R.Add 7 2 (R.Imm 1)
        (* iterations = count + 1 *)
        (* position = ((ds_xfrac<<10) & 0xffff0000) | ((ds_yfrac>>6) & 0xffff) *)
      ; ldw_db 2 ds_xfrac
      ; alu R.Lsl 2 2 (R.Imm 10)
      ]
      @ load_const2 1 0xFFFF_0000
      @ [ alu R.And 2 2 (R.Reg 1)
        ; ldw_db 0 ds_yfrac
        ; alu R.Asr 0 0 (R.Imm 6) (* signed >> *)
        ; alu R.And 0 0 (R.Imm 0xFFFF)
        ; alu R.Ior 2 2 (R.Reg 0) (* step, same shape (mask still in R1) *)
        ; ldw_db 3 ds_xstep
        ; alu R.Lsl 3 3 (R.Imm 10)
        ; alu R.And 3 3 (R.Reg 1)
        ; ldw_db 0 ds_ystep
        ; alu R.Asr 0 0 (R.Imm 6)
        ; alu R.And 0 0 (R.Imm 0xFFFF)
        ; alu R.Ior 3 3 (R.Reg 0) (* dest = ylookup[ds_y] + columnofs[ds_x1] *)
        ; ldw_db 0 ds_y
        ; alu R.Lsl 0 0 (R.Imm 2)
        ; alu R.Add 0 13 (R.Reg 0)
        ; ldw 6 0 ylookup
        ; ldw_db 0 ds_x1
        ; alu R.Lsl 0 0 (R.Imm 2)
        ; alu R.Add 0 13 (R.Reg 0)
        ; ldw 0 0 columnofs
        ; alu R.Add 6 6 (R.Reg 0)
        ; ldw_db 4 ds_source
        ; ldw_db 5 ds_colormap
        ; L.Label l_loop (* spot = ((position>>4) & 0x0fc0) | (position>>26) *)
        ; alu R.Ror 0 2 (R.Imm 4)
        ; alu R.And 0 0 (R.Imm 0x0FC0)
        ; alu R.Ror 1 2 (R.Imm 26)
        ; alu R.And 1 1 (R.Imm 0x3F)
        ; alu R.Ior 0 0 (R.Reg 1) (* *dest++ = ds_colormap[ds_source[spot]] *)
        ; alu R.Add 0 4 (R.Reg 0)
        ; ldb 0 0 0
        ; alu R.Add 0 5 (R.Reg 0)
        ; ldb 0 0 0
        ; ins (R.Store { size = R.B; a = 0; base = 6; off = 0 })
        ; alu R.Add 6 6 (R.Imm 1)
        ; alu R.Add 2 2 (R.Reg 3) (* position += step *)
        ; alu R.Sub 7 7 (R.Imm 1)
        ; bcc_not R.Eq l_loop
        ; ldw 6 14 16
        ; ldw 7 14 20
        ; ldw 15 14 24
        ; alu R.Add 14 14 (R.Imm 36)
        ; ret
        ; L.Label l_err
        ; ldw_db 1 ds_x1
        ; ldw_db 2 ds_x2
        ; ldw_db 3 ds_y
        ]
      @ load_const2 0 fmt
      @ [ alu R.Add 0 13 (R.Reg 0)
        ; bl_sym "I_Error" (* never returns (setjmp-shaped exit) *)
        ; L.Label l_park
        ; L.Jmp l_park
        ]
  }
;;

let column ~off ~str : L.obj =
  let dc_x = off "dc_x"
  and dc_yl = off "dc_yl"
  and dc_yh = off "dc_yh"
  and dc_iscale = off "dc_iscale"
  and dc_texturemid = off "dc_texturemid"
  and dc_colormap = off "dc_colormap"
  and dc_source = off "dc_source"
  and centery = off "centery"
  and ylookup = off "ylookup"
  and columnofs = off "columnofs"
  and fmt = str "R_DrawColumn: %i to %i at %i" in
  let l_loop = 0
  and l_err = 1
  and l_park = 2
  and l_out = 3 in
  { L.name = "R_DrawColumn"
  ; frags =
      [ alu R.Sub 14 14 (R.Imm 36)
      ; stw 6 14 16
      ; stw 7 14 20
      ; stw 15 14 24
      ; ldw_db 0 dc_yh
      ; ldw_db 1 dc_yl
      ; alu R.Sub 7 0 (R.Reg 1) (* count = dc_yh - dc_yl *)
      ; bcc R.Lt l_out
        (* count < 0: return *)
        (* RANGECHECK *)
      ; ldw_db 2 dc_x
      ; alu R.Sub 3 2 (R.Imm 320)
      ; bcc_not R.Cs l_err (* ~C: dc_x >= 320 unsigned *)
      ; alu R.Sub 3 1 (R.Imm 0)
      ; bcc R.Lt l_err (* dc_yl < 0 *)
      ; alu R.Sub 3 0 (R.Imm 200)
      ; bcc_not R.Lt l_err (* dc_yh >= 200 *)
      ; alu R.Add 7 7 (R.Imm 1)
        (* iterations = count + 1 *)
        (* dest = ylookup[dc_yl] + columnofs[dc_x] *)
      ; alu R.Lsl 0 1 (R.Imm 2)
      ; alu R.Add 0 13 (R.Reg 0)
      ; ldw 6 0 ylookup
      ; alu R.Lsl 0 2 (R.Imm 2)
      ; alu R.Add 0 13 (R.Reg 0)
      ; ldw 0 0 columnofs
      ; alu R.Add 6 6 (R.Reg 0)
        (* fracstep; frac = dc_texturemid + (dc_yl - centery) * fracstep *)
      ; ldw_db 3 dc_iscale
      ; ldw_db 0 centery
      ; alu R.Sub 2 1 (R.Reg 0) (* dc_yl - centery *)
      ; alu R.Mul 2 2 (R.Reg 3)
      ; ldw_db 0 dc_texturemid
      ; alu R.Add 2 0 (R.Reg 2) (* frac *)
      ; ldw_db 4 dc_source
      ; ldw_db 5 dc_colormap
      ; L.Label l_loop
      ; alu R.Ror 0 2 (R.Imm 16) (* (frac >> 16) & 127 *)
      ; alu R.And 0 0 (R.Imm 127)
      ; alu R.Add 0 4 (R.Reg 0)
      ; ldb 0 0 0
      ; alu R.Add 0 5 (R.Reg 0)
      ; ldb 0 0 0
      ; ins (R.Store { size = R.B; a = 0; base = 6; off = 0 })
      ; alu R.Add 6 6 (R.Imm 320) (* dest += SCREENWIDTH *)
      ; alu R.Add 2 2 (R.Reg 3) (* frac += fracstep *)
      ; alu R.Sub 7 7 (R.Imm 1)
      ; bcc_not R.Eq l_loop
      ; L.Label l_out
      ; ldw 6 14 16
      ; ldw 7 14 20
      ; ldw 15 14 24
      ; alu R.Add 14 14 (R.Imm 36)
      ; ret
      ; L.Label l_err
      ; ldw_db 1 dc_yl
      ; ldw_db 2 dc_yh
      ; ldw_db 3 dc_x
      ]
      @ load_const2 0 fmt
      @ [ alu R.Add 0 13 (R.Reg 0); bl_sym "I_Error"; L.Label l_park; L.Jmp l_park ]
  }
;;

(* ---- __dg_dither_fs (drawer #4, the legibility pass's out2 kernel) --------------
   The C spec is dither.c's __dg_dither_fs: fullscreen 320x200 -> 1024x768, out2
   decisions (two blue-noise rows per source line, alternating over the 3-4 output
   rows), the sorted-cut rank trick per (bn row, word phase, slot). This is that C
   register-scheduled: the compiled kernel pays ~120 instrs per slot re-deriving
   multi-dim indices; here a slot is ~17-20 — the cut/mask slabs are base registers
   and every slot's cut/mask/src offsets are IMMEDIATES in the unrolled pair body.
   K-aware: 3-cut slots skip the padded 255 compare (it can never fire).

   void __dg_dither_fs(const u8 *src, u32 *dst, int stride)
     args: R0=src  R1=dst  R2=stride (words)

   Frame (SUB SP,72): +0..15 the ABI §3 home area (live during the one-time
   BL __dg_fs_build) · +16..36 R6..R11 · +40 LNK · +44/48/52 the args parked
   across the init call · +56 sy · +60 acc (Bresenham) · +64 b2 (B-pass second
   target row) · +68 adv (dst line advance, rep*stride4)

   Registers, steady: R2 stride4 · R5 &__dg_lum · R6 dst line · R11 src line.
   Per row-pass: R3 cut slab (&cut[bnrow]) · R4 mask slab · R0 src cursor ·
   R8 out1 · R1 out2 · R7 pairs left · R10 bits · R9 lum · R12/R15 temps.

   The slot step (cut offsets 4s, mask offsets 20s, src offsets s — s = p*10+j):
     LDB R12,[R0+s]; ADD R12,R5,R12; LDB R9,[R12]     lum
     MOV R15,0                                         rank
     Kx: LDB R12,[R3,4s+c]; SUB R12,R12,R9; ADD' R15,R15,0
         (C = cut < lum strict, the s5.2 convention; loads leave C alone)
     LSL R15,2; ADD R15,R4,R15; LDW R12,[R15,20s]; IOR R10,R10,R12
   A-pass rows land at dst and dst+2*stride4; B-pass at dst+stride4 and b2 —
   b2 = dst+3*stride4 when the line deals 4 rows, else = the B row again (a
   harmless duplicate store beats a branch in the row loop). *)

let xw_fs = [| 3; 3; 3; 3; 4; 3; 3; 3; 3; 4 |]

let dither_fs ~lum_off ~cut_off ~mask_off ~ready_off : L.obj =
  let l_line = 0
  and l_rep3 = 1
  and l_bres = 2
  and l_pair_a = 3
  and l_pair_b = 4
  and l_inited = 5 in
  let slot s =
    [ ldb 12 0 s; alu R.Add 12 5 (R.Reg 12); ldb 9 12 0; movi 15 0 ]
    @ List.concat_map
        (fun c ->
           [ ldb 12 3 ((4 * s) + c)
           ; alu R.Sub 12 12 (R.Reg 9)
           ; alu ~u:true R.Add 15 15 (R.Imm 0)
           ])
        (List.init xw_fs.(s mod 10) Fun.id)
    @ [ alu R.Lsl 15 15 (R.Imm 2)
      ; alu R.Add 15 4 (R.Reg 15)
      ; ldw 12 15 (20 * s)
      ; alu R.Ior 10 10 (R.Reg 12)
      ]
  in
  let word p =
    (movi 10 0 :: List.concat_map slot (List.init 10 (fun j -> (10 * p) + j)))
    @ [ stw 10 8 0; stw 10 1 0; alu R.Add 8 8 (R.Imm 4); alu R.Add 1 1 (R.Imm 4) ]
  in
  let pair_loop l =
    [ L.Label l ]
    @ word 0
    @ word 1
    @ [ alu R.Add 0 0 (R.Imm 20); alu R.Sub 7 7 (R.Imm 1); bcc_not R.Eq l ]
  in
  (* R12 = bn row on entry; leaves R3 = &cut[row], R4 = &mask[row] *)
  let slabs =
    [ alu R.Mul 15 12 (R.Imm 80) ]
    @ load_const2 3 cut_off
    @ [ alu R.Add 3 13 (R.Reg 3); alu R.Add 3 3 (R.Reg 15); alu R.Mul 15 12 (R.Imm 400) ]
    @ load_const2 4 mask_off
    @ [ alu R.Add 4 13 (R.Reg 4); alu R.Add 4 4 (R.Reg 15) ]
  in
  let bn_row_from_sy =
    [ ldw 12 14 56; alu R.Lsl 12 12 (R.Imm 1); alu R.And 12 12 (R.Imm 63) ]
  in
  { L.name = "__dg_dither_fs"
  ; frags =
      [ alu R.Sub 14 14 (R.Imm 72)
      ; stw 6 14 16
      ; stw 7 14 20
      ; stw 8 14 24
      ; stw 9 14 28
      ; stw 10 14 32
      ; stw 11 14 36
      ; stw 15 14 40
      ; stw 0 14 44
      ; stw 1 14 48
      ; stw 2 14 52
      ; ldw 12 13 ready_off
      ; L.Bcc (R.Eq, true, l_inited)
      ; L.Call "__dg_fs_build" (* one-time; the home area at SP+0 is its *)
      ; L.Label l_inited (* ABI §3 due *)
      ; ldw 11 14 44 (* src line *)
      ; ldw 6 14 48 (* dst line *)
      ; ldw 2 14 52
      ; alu R.Lsl 2 2 (R.Imm 2) (* stride4 *)
      ]
      @ load_const2 5 lum_off
      @ [ alu R.Add 5 13 (R.Reg 5)
        ; movi 12 0
        ; stw 12 14 56 (* sy = 0 *)
        ; stw 12 14 60 (* acc = 0 *)
        ; L.Label l_line
          (* acc += 96 then 3 subs fold to t = acc+21; a 4th row iff t >= 25 *)
        ; ldw 12 14 60
        ; alu R.Add 12 12 (R.Imm 21)
        ; alu R.Sub 15 12 (R.Imm 25)
        ; L.Bcc (R.Cs, false, l_rep3)
        ; alu R.Sub 12 12 (R.Imm 25) (* rep = 4 *)
        ; stw 12 14 60
        ; alu R.Lsl 15 2 (R.Imm 2)
        ; stw 15 14 68 (* adv = 4*stride4 *)
        ; alu R.Lsl 15 2 (R.Imm 1)
        ; alu R.Add 15 15 (R.Reg 2)
        ; alu R.Add 15 6 (R.Reg 15)
        ; stw 15 14 64 (* b2 = dst + 3*stride4 *)
        ; L.Jmp l_bres
        ; L.Label l_rep3
        ; stw 12 14 60 (* rep = 3 *)
        ; alu R.Lsl 15 2 (R.Imm 1)
        ; alu R.Add 15 15 (R.Reg 2)
        ; stw 15 14 68 (* adv = 3*stride4 *)
        ; alu R.Add 15 6 (R.Reg 2)
        ; stw 15 14 64 (* b2 = the B row again (dup store) *)
        ; L.Label l_bres
        ]
      @ bn_row_from_sy (* A: bn row = (2*sy) & 63 *)
      @ slabs
      @ [ mov 8 6 (* out1 = dst row 0 *)
        ; alu R.Lsl 15 2 (R.Imm 1)
        ; alu R.Add 1 6 (R.Reg 15) (* out2 = dst row 2 *)
        ; mov 0 11
        ; movi 7 16
        ]
      @ pair_loop l_pair_a
      @ bn_row_from_sy
      @ [ alu R.Add 12 12 (R.Imm 1) (* B: bn row = 2*sy + 1 (2*sy is even: no wrap) *) ]
      @ slabs
      @ [ alu R.Add 8 6 (R.Reg 2) (* out1 = dst row 1 *)
        ; ldw 1 14 64 (* out2 = b2 *)
        ; mov 0 11
        ; movi 7 16
        ]
      @ pair_loop l_pair_b
      @ [ alu R.Add 11 11 (R.Imm 320)
        ; ldw 12 14 68
        ; alu R.Add 6 6 (R.Reg 12)
        ; ldw 12 14 56
        ; alu R.Add 12 12 (R.Imm 1)
        ; stw 12 14 56
        ; alu R.Sub 15 12 (R.Imm 200)
        ; bcc_not R.Eq l_line
        ; ldw 6 14 16
        ; ldw 7 14 20
        ; ldw 8 14 24
        ; ldw 9 14 28
        ; ldw 10 14 32
        ; ldw 11 14 36
        ; ldw 15 14 40
        ; alu R.Add 14 14 (R.Imm 72)
        ; ret
        ]
  }
;;

(* ---- __dg_frame_copy (drawer #5, feat/halftone) --------------------------------
   The C spec is dither.c's __dg_frame_copy: the hw-scanout path's per-frame block
   copy, 16000 words, both ends word-aligned by contract. Compiled it pays ~20
   instrs/word (naive fixed-home codegen); here 1000 iterations of a 16-pair body
   with immediate offsets run 36 instrs per 16 words (~2.3/word).

   void __dg_frame_copy(const u8 *src, u8 *dst)
     args: R0=src  R1=dst

   Leaf, no frame: clobbers R0-R3 only (all caller-saved). R2 = iterations left,
   R3 = the word in flight. *)

let frame_copy : L.obj =
  let l_loop = 0 in
  { L.name = "__dg_frame_copy"
  ; frags =
      [ movi 2 1000; L.Label l_loop ]
      @ List.concat_map
          (fun k -> [ ldw 3 0 (4 * k); stw 3 1 (4 * k) ])
          (List.init 16 Fun.id)
      @ [ alu R.Add 0 0 (R.Imm 64)
        ; alu R.Add 1 1 (R.Imm 64)
        ; alu R.Sub 2 2 (R.Imm 1)
        ; bcc_not R.Eq l_loop
        ; ret
        ]
  }
;;

(* Build every drawer whose data symbols resolve; each is independent — a sample
   (or a tree) lacking a drawer's globals simply keeps its compiled version. *)
let build ~(off : string -> int option) ~(str : string -> int option) : L.obj list =
  let req f name =
    match f name with
    | Some v -> v
    | None -> raise Exit
  in
  let try_build b =
    try [ b ~off:(req off) ~str:(req str) ] with
    | Exit -> []
  in
  let dither_b ~off ~str:_ = dither ~lum_off:(off "__dg_lum") ~bn_off:(off "__dg_bn64") in
  let dither_fs_b ~off ~str:_ =
    dither_fs
      ~lum_off:(off "__dg_lum")
      ~cut_off:(off "__dg_fs_cut")
      ~mask_off:(off "__dg_fs_mask")
      ~ready_off:(off "__dg_fs_ready")
  in
  try_build dither_b
  @ try_build dither_fs_b
  @ try_build span
  @ try_build column
  @ [ frame_copy ]
;;
(* consults no symbols — nothing to fail on *)
