(* Execute one compiled function (a Risc5_isa.instr list) in the vendored emulator — the
   execution half of the differential jig (AGENT.md §7). Place [args] in R0.., load the
   encoded instrs at [code_base], run until the function returns, read R0.

   As of s4.1a the function is a proper ABI callee: it opens a frame, saves the callee-saved
   regs it clobbers, and returns via [B LNK] (register-target branch). So the Runner plays the
   *caller* — it sets SP, seeds LNK with a sentinel that lands one past the code (so [B LNK]
   halts exactly where fall-off-the-end used to), and — the point — seeds R6-R11 with known
   values and checks after return that they, and SP, came back untouched. That turns every
   sample into a callee-saved-contract + frame-balance test without needing a real call yet
   (a broken save/restore can't show up in R0 alone — no caller observes R6-R11 otherwise). *)

module Isa = Emu.Risc5_isa
module M = Emu.Risc

(* A word index safely inside RAM (the emulator's PC and RAM are word-indexed; ROM sits at
   0xFFE000, so 0x1000 is plain RAM — mirrors test_cpu_lockstep's base_pc). *)
let code_base = 0x1000

(* Byte address of the data segment: the [Globals.t] image lands here and DB (R13, ABI §2)
   points at it — the jig-sized version of crt0's job. 0x80000 sits clear of the code
   (byte 0x4000) and the display shadow (0xE7F00) inside the emulator's 1 MB RAM. *)
let data_base = 0x80000

(* Top of the C stack (SP, R14; full-descending, ABI §2). Byte 0x70000 sits below the data
   segment (0x80000) and well above the code — the frame grows down into the gap. *)
let stack_top = 0x70000

(* Callee-saved registers R6-R11 (ABI §2) seeded with recognizable sentinels; a correct
   callee saves and restores exactly the ones it writes, so all six must survive the call. *)
let callee_saved = [ 6; 7; 8; 9; 10; 11 ]
let sentinel r = 0xCAFE_0000 lor r land 0xFFFF_FFFF

(* Runaway guard: any correct function over the jig's bounded inputs halts well within this, so
   hitting it means a codegen bug (mis-resolved branch / non-terminating loop), not a slow
   program — fail loud rather than spin forever. *)
let max_steps = 1_000_000

let run ?(data = Bytes.empty) (body : Isa.instr list) (args : int list) : int =
  let m = M.make () in
  let ram = M.For_tests.ram m in
  List.iteri (fun i instr -> ram.(code_base + i) <- Isa.encode instr) body;
  (* fresh data segment per run (mutating bodies stay deterministic) + DB, crt0-style *)
  for i = 0 to (Bytes.length data / 4) - 1 do
    ram.((data_base / 4) + i)
    <- Int32.to_int (Bytes.get_int32_le data (i * 4)) land 0xFFFF_FFFF
  done;
  let regs = M.For_tests.regs m in
  regs.(13) <- data_base;
  regs.(14) <- stack_top;
  (* [B LNK] sets PC = R15/4 (emulator, risc.ml); a sentinel one past the body lands the
     return exactly on the stop word below, so returning halts like fall-off-the-end did. *)
  let stop = code_base + List.length body in
  regs.(15) <- stop * 4;
  List.iter (fun r -> regs.(r) <- sentinel r) callee_saved;
  (* args 1-4 in R0-R3; args 5+ on the stack at SP+4i (ABI §3, s4.2). Entry SP = stack_top, so
     the callee reads arg i at FP+4i = stack_top+4i — words just above SP, in the notional
     caller's frame (clear of the descending stack, the code, and the data segment). *)
  List.iteri
    (fun i v ->
       let v = v land 0xFFFF_FFFF in
       if i < 4 then regs.(i) <- v else ram.((stack_top / 4) + i) <- v)
    args;
  M.For_tests.set_pc m code_base;
  let rec loop n =
    if M.For_tests.pc m >= stop
    then ()
    else if n >= max_steps
    then
      failwith
        "Runner.run: step cap exceeded (mis-resolved branch / non-terminating body?)"
    else (
      (* the synthetic ms clock ticks with the instruction count (1 ms per 1024
         steps — the rate is arbitrary, monotonicity is the contract), so
         time-dependent code (DG_SleepMs's spin on the ms counter) terminates
         instead of reading a frozen clock into the step cap *)
      M.set_time m (n asr 10);
      M.For_tests.single_step m;
      loop (n + 1))
  in
  loop 0;
  let regs = M.For_tests.regs m in
  (* the ABI callee contract: SP restored, every callee-saved register preserved *)
  if regs.(14) <> stack_top
  then
    failwith
      (Printf.sprintf
         "Runner.run: SP not restored (frame imbalance): got 0x%X want 0x%X"
         regs.(14)
         stack_top);
  List.iter
    (fun r ->
       if regs.(r) <> sentinel r
       then
         failwith
           (Printf.sprintf
              "Runner.run: callee-saved R%d clobbered: got 0x%X want 0x%X (missing \
               save/restore)"
              r
              regs.(r)
              (sentinel r)))
    callee_saved;
  regs.(0)
;;
