(* Execute a leaf body (a Risc5_isa.instr list) in the vendored emulator — the execution
   half of the differential jig (AGENT.md §7). Place [args] in R0.., load the encoded instrs
   at [code_base], run until control falls off the end of the body (intra-body branches may loop
   or skip), read R0. Intra-body branches only — no calls; the prologue/epilogue and the
   register-target return branch arrive with the call slice. *)

module Isa = Emu.Risc5_isa
module M = Emu.Risc

(* A word index safely inside RAM (the emulator's PC and RAM are word-indexed; ROM sits at
   0xFFE000, so 0x1000 is plain RAM — mirrors test_cpu_lockstep's base_pc). *)
let code_base = 0x1000

(* Byte address of the data segment: the [Globals.t] image lands here and DB (R13, ABI §2)
   points at it — the jig-sized version of crt0's job. 0x80000 sits clear of the code
   (byte 0x4000) and the display shadow (0xE7F00) inside the emulator's 1 MB RAM. *)
let data_base = 0x80000

(* Runaway guard: any correct leaf over the jig's bounded inputs halts well within this, so
   hitting it means a codegen bug (mis-resolved branch / non-terminating loop), not a slow
   program — fail loud rather than spin forever. *)
let max_steps = 1_000_000

let run_leaf ?(data = Bytes.empty) (body : Isa.instr list) (args : int list) : int =
  let m = M.make () in
  let ram = M.For_tests.ram m in
  List.iteri (fun i instr -> ram.(code_base + i) <- Isa.encode instr) body;
  (* fresh data segment per run (mutating bodies stay deterministic) + DB, crt0-style *)
  for i = 0 to (Bytes.length data / 4) - 1 do
    ram.((data_base / 4) + i) <- Int32.to_int (Bytes.get_int32_le data (i * 4)) land 0xFFFF_FFFF
  done;
  let regs = M.For_tests.regs m in
  regs.(13) <- data_base;
  List.iteri (fun i v -> regs.(i) <- v land 0xFFFF_FFFF) args;
  M.For_tests.set_pc m code_base;
  (* "Done" = control reached the word just past the body — fell through the last instr, or
     a return-branch jumped there. Every intra-body branch lands inside [code_base, stop). *)
  let stop = code_base + List.length body in
  let rec loop n =
    if M.For_tests.pc m >= stop
    then ()
    else if n >= max_steps
    then failwith "Runner.run_leaf: step cap exceeded (mis-resolved branch / non-terminating body?)"
    else begin
      M.For_tests.single_step m;
      loop (n + 1)
    end
  in
  loop 0;
  (M.For_tests.regs m).(0)
