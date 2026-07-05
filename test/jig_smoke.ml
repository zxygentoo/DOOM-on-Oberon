(* feat/cil-backend bring-up: emit -> encode -> run, through the vendored emulator.

   Proves the sourcing decision (vendor the emulator) works end to end: build a
   Risc5_isa.instr by hand, encode it to a word, load it into the emulator's RAM, run one
   step per instruction, read the result register. No CIL yet — this is the *execution*
   half of the differential jig (DOOM.md §7). Later it runs *compiled* instr lists and
   diffs R0 against host gcc; the codegen (CIL typed AST -> Risc5_isa.instr) slots in
   above run_leaf. *)

module Isa = Emu.Risc5_isa
module M = Emu.Risc

(* A word index safely inside RAM (mirrors test_cpu_lockstep's base_pc: the emulator's
   PC and RAM are word-indexed, ROM sits up at 0xFFE000, so 0x1000 is plain RAM). *)
let base = 0x1000

let u32 x = x land 0xFFFF_FFFF

(* SEAM §3a ABI: integer args in R0..R3, return value in R0.

   Run a straight-line instr list as a leaf body: pre-place [args] in R0.., point PC at
   the first instr, single-step once per instr, read R0. A straight-line body needs no
   prologue/epilogue/return-branch — those arrive with the real codegen. *)
let run_leaf (body : Isa.instr list) (args : int list) : int =
  let m = M.make () in
  let ram = M.For_tests.ram m in
  List.iteri (fun i instr -> ram.(base + i) <- Isa.encode instr) body;
  let regs = M.For_tests.regs m in
  List.iteri (fun i v -> regs.(i) <- u32 v) args;
  M.For_tests.set_pc m base;
  List.iter (fun _ -> M.For_tests.single_step m) body;
  (M.For_tests.regs m).(0)
;;

let () =
  (* int add(int a, int b) { return a + b; }  ->  ADD R0, R0, R1  (a in R0, b in R1) *)
  let add =
    Isa.[ Alu { op = Add; u = false; v = false; a = 0; b = 0; operand = Reg 1 } ]
  in
  let cases =
    [ 2, 3
    ; 0, 0
    ; -1, 1 (* wrap to 0 *)
    ; 0x7FFF_FFFF, 1 (* signed overflow, unsigned exact *)
    ; 0xFFFF_FFFF, 0xFFFF_FFFF
    ; 123456, 654321
    ]
  in
  List.iter
    (fun (a, b) ->
      let got = run_leaf add [ a; b ] in
      let want = u32 (u32 a + u32 b) in
      if got <> want
      then
        failwith
          (Printf.sprintf
             "ADD R0,R0,R1: a=%08x b=%08x got=%08x want=%08x"
             (u32 a)
             (u32 b)
             got
             want))
    cases;
  Printf.printf
    "jig smoke: emit -> encode -> run OK (ADD R0,R0,R1, %d cases) via vendored emulator @ e36fcf0\n"
    (List.length cases)
;;
