(* Execute a straight-line leaf body (a Risc5_isa.instr list) in the vendored emulator —
   the execution half of the differential jig (DOOM.md §7). Place [args] in R0.., load the
   encoded instrs at [base], single-step once per instr, read R0. Straight-line only (no
   branches/calls): prologue/epilogue and the return branch arrive with the call slice. *)

module Isa = Emu.Risc5_isa
module M = Emu.Risc

(* A word index safely inside RAM (the emulator's PC and RAM are word-indexed; ROM sits at
   0xFFE000, so 0x1000 is plain RAM — mirrors test_cpu_lockstep's base_pc). *)
let base = 0x1000

let run_leaf (body : Isa.instr list) (args : int list) : int =
  let m = M.make () in
  let ram = M.For_tests.ram m in
  List.iteri (fun i instr -> ram.(base + i) <- Isa.encode instr) body;
  let regs = M.For_tests.regs m in
  List.iteri (fun i v -> regs.(i) <- v land 0xFFFF_FFFF) args;
  M.For_tests.set_pc m base;
  List.iter (fun _ -> M.For_tests.single_step m) body;
  (M.For_tests.regs m).(0)
