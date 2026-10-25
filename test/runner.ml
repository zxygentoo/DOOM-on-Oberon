(* Run one compiled function in the vendored emulator — the jig's execution half.
   The Runner plays the caller: args in R0.. (5+ on the stack), a stop sentinel in LNK,
   and R6-R12 seeded with sentinels. After the return it checks SP and R6-R12 came back
   intact, so every sample is also a callee-saved-contract and frame-balance test. *)

module Isa = Emu.Risc5_isa
module M = Emu.Risc

(* a word index: the emulator's PC and RAM are word-indexed *)
let code_base = 0x1000

(* byte address of the data image, where DB points; clear of the code and the
   framebuffer at 0xE7F00 *)
let data_base = 0x80000

(* below the data image; the stack grows down into the gap *)
let stack_top = 0x70000
let callee_saved = [ 6; 7; 8; 9; 10; 11; 12 ]
let sentinel r = 0xCAFE_0000 lor r land 0xFFFF_FFFF

(* a runaway guard: hitting it means a codegen bug; long samples pass [steps] *)
let max_steps = 1_000_000

let run
      ?(data = Bytes.empty)
      ?(steps = max_steps)
      (body : Isa.instr list)
      (args : int list)
  : int
  =
  let m = M.make () in
  let ram = M.For_tests.ram m in
  List.iteri (fun i instr -> ram.(code_base + i) <- Isa.encode instr) body;
  (* fresh per run, so mutating samples stay deterministic *)
  for i = 0 to (Bytes.length data / 4) - 1 do
    ram.((data_base / 4) + i)
    <- Int32.to_int (Bytes.get_int32_le data (i * 4)) land 0xFFFF_FFFF
  done;
  let regs = M.For_tests.regs m in
  regs.(13) <- data_base;
  regs.(14) <- stack_top;
  (* B LNK to a sentinel one past the body lands on the stop word *)
  let stop = code_base + List.length body in
  regs.(15) <- stop * 4;
  List.iter (fun r -> regs.(r) <- sentinel r) callee_saved;
  (* args 5+ at stack_top + 4i, where the callee reads them as FP + 4i *)
  List.iteri
    (fun i v ->
       let v = v land 0xFFFF_FFFF in
       if i < 4 then regs.(i) <- v else ram.((stack_top / 4) + i) <- v)
    args;
  M.For_tests.set_pc m code_base;
  let rec loop n =
    if M.For_tests.pc m >= stop
    then ()
    else if n >= steps
    then
      failwith
        "Runner.run: step cap exceeded (mis-resolved branch / non-terminating body?)"
    else (
      (* a synthetic ms clock (1 ms per 1024 steps), so code that spins on the ms
         counter (DG_SleepMs) terminates instead of hitting the step cap *)
      M.set_time m (n asr 10);
      M.For_tests.single_step m;
      loop (n + 1))
  in
  loop 0;
  let regs = M.For_tests.regs m in
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
