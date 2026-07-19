(* The crt0 entry thunks (ABI §7). See crt0.mli. The shape, verbatim from the spec:

     save R6-R15 -> save area in blob data   ; Oberon's world, parked
     SP  = STACK_TOP ; SUB SP, SP, 16        ; C stack + initial home area
     DB  = data base
     BL   <C entry>                          ; args already in R0/R1 (§3)
     restore R6-R15
     B    LNK                                ; back to the stub

   The saving chicken-egg: storing R6-R15 needs a base register for the save-area
   address, but every high register is Oberon's. R0-R5 are outside the save contract
   (the stub expects caller-saved clobbers; Wirth's compiler keeps nothing live there
   across a call) and R0/R1 carry the entry's args — so R5 takes the address, and is
   reloaded for the restore (the C entry clobbered it). LNK itself is saved as R15 and
   restored before the final B LNK, so the thunk returns to the stub even though its
   own BL overwrote it. All constants use the fixed 2-word load (Asm.load_const2,
   even for a zero high half): the thunk's size must not depend on values that only
   exist after layout — the same discipline as the linker's Addr frag. *)

module R = Emu.Risc5_isa
module L = Linker
open Asm

let save_area_size = 40 (* R6-R15: 10 words *)

let saves base_reg area_to_ins =
  List.init 10 (fun i -> ins (area_to_ins (6 + i) base_reg (4 * i)))
;;

(* loads(2) + saves(10) + SP(2) + DB(2) + BL(1) + reload(2) + restores(10) + ret(1) *)
let size = 2 + 10 + 2 + 2 + 1 + 2 + 10 + 1

let thunk ~name ~entry ~save_area ~stack_top ~data_base : L.obj =
  let frags =
    load_const2 5 save_area
    @ saves 5 (fun r base off -> R.Store { size = R.W; a = r; base; off })
    @ load_const2 14 (stack_top - 16) (* SP: C stack, minus the o32 home area *)
    @ load_const2 13 data_base (* DB *)
    @ [ L.Call entry ]
    @ load_const2 5 save_area (* the C entry clobbered R5 *)
    @ saves 5 (fun r base off -> R.Load { size = R.W; a = r; base; off })
    @ [ ret ]
  in
  let o = { L.name; frags } in
  assert (L.code_size o = size);
  o
;;
