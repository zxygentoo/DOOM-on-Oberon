(* feat/cil-backend bring-up: emit -> encode -> run, through the vendored emulator.

   The first plumbing proof (slice 0): build a Risc5_isa.instr by hand, encode it, and run
   it via Backend.Runner (the shared emulator exec the differential jig also uses). The real
   CIL -> instr codegen lives in Backend.Codegen and is exercised by test_codegen. *)

module Isa = Emu.Risc5_isa

let u32 x = x land 0xFFFF_FFFF

let () =
  (* int add(int a, int b) { return a + b; }  ->  ADD R0, R0, R1  (a in R0, b in R1) *)
  let add = Isa.[ Alu { op = Add; u = false; v = false; a = 0; b = 0; operand = Reg 1 } ] in
  let cases =
    [ 2, 3; 0, 0; -1, 1; 0x7FFF_FFFF, 1; 0xFFFF_FFFF, 0xFFFF_FFFF; 123456, 654321 ]
  in
  List.iter
    (fun (a, b) ->
      let got = Backend.Runner.run_leaf add [ a; b ] in
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
    "runner smoke: emit -> encode -> run OK (ADD R0,R0,R1, %d cases) via Backend.Runner\n"
    (List.length cases)
