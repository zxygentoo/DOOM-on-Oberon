module R = Emu.Risc5_isa
module L = Linker
open Asm

let save_area_size = 40

let saves base_reg area_to_ins =
  List.init 10 (fun i -> ins (area_to_ins (6 + i) base_reg (4 * i)))
;;

(* loads(2) + saves(10) + SP(2) + DB(2) + BL(1) + reload(2) + restores(10) + ret(1) *)
let size = 2 + 10 + 2 + 2 + 1 + 2 + 10 + 1

let thunk ~name ~entry ~save_area ~stack_top ~data_base : L.obj =
  let frags =
    load_const2 5 save_area
    @ saves 5 (fun r base off -> R.Store { size = R.W; a = r; base; off })
    @ load_const2 14 (stack_top - 16) (* SP, below the 16-byte home area *)
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
