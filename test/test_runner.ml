(* feat/cil-backend bring-up: emit -> encode -> run, through the vendored emulator.

   The plumbing proof: build Risc5_isa.instr lists by hand, encode them, and run them via
   Runner (the jig's shared emulator exec, test-local). Beyond the first straight-line ADD,
   this pins — in isolation, before Fundec emits a single branch — the branch mechanism the
   control-flow slice is built on: the PC-relative offset arithmetic
   (off = target - branch - 1), signed-compare flags (Lt = N≠V, Le = (N≠V)|Z, from SUB), and
   run-until-fall-off-the-end termination. The real CIL -> instr compilation lives in
   doomcc_core's Fundec and is exercised by test_jig. *)

module Isa = Emu.Risc5_isa

let u32 x = x land 0xFFFF_FFFF

(* ADD R0,R0,R1 — the original straight-line smoke (a in R0, b in R1). *)
let add = Isa.[ Alu { op = Add; u = false; v = false; a = 0; b = 0; operand = Reg 1 } ]

(* Forward branches + signed compare + fall-off-end:
     if (a < b) return 111 else return 222        (a in R0, b in R1)
       0: SUB R2,R0,R1   ; flags = a - b   (R2 dead)
       1: B!(Lt) -> 4    ; !(a<b): {Lt,neg=true}   off = 4-1-1 = 2
       2: MOV R0,111
       3: B     -> 5     ; skip else (end)          off = 5-3-1 = 1
       4: MOV R0,222 *)
let select =
  Isa.
    [ Alu { op = Sub; u = false; v = false; a = 2; b = 0; operand = Reg 1 }
    ; Branch { cond = Lt; neg = true; link = false; target = To_off 2 }
    ; Alu { op = Mov; u = false; v = false; a = 0; b = 0; operand = Imm 111 }
    ; Branch { cond = True; neg = false; link = false; target = To_off 1 }
    ; Alu { op = Mov; u = false; v = false; a = 0; b = 0; operand = Imm 222 }
    ]

(* Backward branch + loop termination + SUB-immediate:
     s = 0; while (n > 0) { s += n; n--; } return s      (n in R0)
       0: MOV R3,0       ; s
       1: MOV R4,0       ; zero
       2: SUB R5,R0,R4   ; flags = n - 0   (loop top)
       3: B(Le) -> 7     ; n<=0 exit                 off = 7-3-1 = 3
       4: ADD R3,R3,R0   ; s += n
       5: SUB R0,R0,1    ; n--
       6: B     -> 2     ; loop                       off = 2-6-1 = -5
       7: MOV R0,R3      ; return s *)
let countdown =
  Isa.
    [ Alu { op = Mov; u = false; v = false; a = 3; b = 0; operand = Imm 0 }
    ; Alu { op = Mov; u = false; v = false; a = 4; b = 0; operand = Imm 0 }
    ; Alu { op = Sub; u = false; v = false; a = 5; b = 0; operand = Reg 4 }
    ; Branch { cond = Le; neg = false; link = false; target = To_off 3 }
    ; Alu { op = Add; u = false; v = false; a = 3; b = 3; operand = Reg 0 }
    ; Alu { op = Sub; u = false; v = false; a = 0; b = 0; operand = Imm 1 }
    ; Branch { cond = True; neg = false; link = false; target = To_off (-5) }
    ; Alu { op = Mov; u = false; v = false; a = 0; b = 0; operand = Reg 3 }
    ]

let checked = ref 0

let check name args got want =
  incr checked;
  if got <> want
  then
    failwith
      (Printf.sprintf
         "%s (args=%s): got=%d want=%d"
         name
         (String.concat "," (List.map string_of_int args))
         got
         want)

let () =
  (* straight-line ADD, incl. 32-bit wrap *)
  List.iter
    (fun (a, b) ->
      check "ADD" [ a; b ] (Runner.run_leaf add [ a; b ]) (u32 (u32 a + u32 b)))
    [ 2, 3; 0, 0; -1, 1; 0x7FFF_FFFF, 1; 0xFFFF_FFFF, 0xFFFF_FFFF; 123456, 654321 ];
  (* forward branches: signed select *)
  List.iter
    (fun (a, b) ->
      check
        "SELECT"
        [ a; b ]
        (Runner.run_leaf select [ a; b ])
        (if a < b then 111 else 222))
    [ 3, 5; 5, 3; 5, 5; -1, 0; 0, -1; -7, -3 ];
  (* backward branch: bounded loop, incl. n<=0 (immediate exit) *)
  List.iter
    (fun n ->
      check
        "LOOP"
        [ n ]
        (Runner.run_leaf countdown [ n ])
        (if n > 0 then n * (n + 1) / 2 else 0))
    [ 0; 1; 5; 10; 100; -3 ];
  Printf.printf
    "runner: emit -> encode -> run OK — %d cases (ADD, forward-branch select, backward-branch loop)\n"
    !checked
