(* run_blob — the blob on the emulator, loaded the way DOOM.Mod loads it.

   Loads the blob at BLOB_BASE and the WAD at WAD_BASE (ABI §8), verifies the §7
   header, zeroes bss, fills the SHARED page, and calls Init, then Tick, through the
   crt0 thunks; the blob's printf arrives on stdout. The ms counter is synthetic: it
   advances every -steps-per-ms instructions (default 44 000 ≈ 60 MHz at CPI 1.37),
   so a run reproduces exactly and the fps -timedemo prints roughly models the board.
   Frames dump as 1024×768 PGMs, logged with their Headless FNV hash.

   A PC that doesn't advance across a step is one of doomcc's self-loop traps; the
   run fails with its address, for a lookup in doom.blob.map.

   Usage: run_blob [options] <doom.blob> <doom1.wad>   (options: [usage], or -help) *)

module M = Emu.Risc
module F = Emu.Risc.For_tests
module Isa = Emu.Risc5_isa
module H = Emu.Headless
module AC = Abi_constants

let blob_base = AC.blob_base
let shared_base = AC.shared_base
let wad_cap = AC.wad_window_end - AC.wad_base
let fail = Run_harness.fail
let read_file = Run_harness.read_file

let usage =
  "usage: run_blob [options] <doom.blob> <doom1.wad>\n\
  \  -ticks N            Ticks to run after Init (default 10)\n\
  \  -dump-every N       PGM-dump every Nth tick and the last (default 1; 0 = the\n\
  \                      last only); off under -dump-at\n\
  \  -dump-at G,G,...    dump frame_gNNNNN.fbw + .pgm at these gametics (with\n\
  \                      -args \"-timedemo demo1\": the golden-oracle format)\n\
  \  -args \"TAIL\"        the DOOM command tail, e.g. -args \"-timedemo demo1\"\n\
  \  -keys T:K:P,...     scripted KeyIn events (tick:doomkey:pressed, decimal)\n\
  \  -hw                 advertise the Halftone scanout (frame dumps go blank)\n\
  \  -profile FILE       flat profile of the Tick loop, by doom.blob.map symbol\n\
  \  -steps-per-ms N     the synthetic ms clock (default 44000)\n\
  \  -max-steps N        step budget per entry call (default 2000000000)"
;;

let ticks = ref 10
let dump_every = ref 1
let steps_per_ms = ref 44_000
let max_steps = ref 2_000_000_000
let blob_args = ref ""
let dump_at = ref ""
let profile_out = ref ""
let keys_spec = ref ""
let hw = ref false
let inputs = ref []

(* -profile state: counts.(w) = executions of code word [base_word + w] *)
let profile_counts = ref [||]
let profile_base_word = ref 0

let rec parse_args = function
  | "-ticks" :: n :: rest -> set_int ticks n rest
  | "-dump-every" :: n :: rest -> set_int dump_every n rest
  | "-steps-per-ms" :: n :: rest -> set_int steps_per_ms n rest
  | "-max-steps" :: n :: rest -> set_int max_steps n rest
  | "-args" :: s :: rest ->
    (* written to SHARED +1024 before Init. Under -timedemo the engine runs one
       gametic per Tick, so -dump-every dumps at exact gametics, and the run ends
       through G_CheckDemoStatus's I_Error ("timed N gametics" on the console,
       status negative): that unwind is the success path. *)
    blob_args := s;
    parse_args rest
  | "-profile" :: p :: rest ->
    (* executions per code word over the Tick loop (Init excluded), aggregated
       by doom.blob.map symbol. Opcode classes are decoded from the blob once,
       per word, so the instruction mix costs nothing per step. *)
    profile_out := p;
    parse_args rest
  | "-keys" :: s :: rest ->
    (* each event goes through the real KeyIn entry just before its Tick, so the
       ring, the responders and the menus all run; menu quit is Esc, 'q', 'y'
       (doomkeys 27, 113, 121) *)
    keys_spec := s;
    parse_args rest
  | "-hw" :: rest ->
    (* SHARED +544 bit 0 (ABI §11). The emulator has no Halftone — the window
       is plain RAM — but the blob takes the hardware path (frame copy and LUT
       upload instead of the dither), so -profile measures that workload. The
       mono fb is never written, so frame dumps go blank. *)
    hw := true;
    parse_args rest
  | "-dump-at" :: s :: rest ->
    (* needs -args "-timedemo demo1": gametic = Ticks + 1, here as in
       bin/doom_golden.c, so neither side reads game memory to align.
       frame_gNNNNN.fbw is the raw fb window, the format of the generator's
       golden_gNNNNN.fbw: cmp(1) of the pair is the oracle. A .pgm rides
       along. Pick gametics past the demo-start wipe (>= 100). *)
    dump_at := s;
    parse_args rest
  | ("-help" | "--help") :: _ ->
    print_endline usage;
    exit 0
  | a :: _ when String.length a > 1 && a.[0] = '-' ->
    (* a typo'd flag would otherwise land as a positional input and surface as a
       misleading usage error *)
    fail "run_blob: unknown flag, or a flag missing its value: %s\n%s" a usage
  | a :: rest ->
    inputs := a :: !inputs;
    parse_args rest
  | [] -> ()

and set_int r n rest =
  match int_of_string_opt n with
  | Some v ->
    r := v;
    parse_args rest
  | None -> fail "run_blob: not an integer: %s" n
;;

let word_of_bytes b off = Int32.to_int (Bytes.get_int32_le b off) land 0xFFFF_FFFF

let load_image ram base (b : bytes) =
  let n = Bytes.length b in
  if n land 3 <> 0 then fail "run_blob: image length %d not word-aligned" n;
  for w = 0 to (n / 4) - 1 do
    ram.((base / 4) + w) <- word_of_bytes b (4 * w)
  done
;;

let verify_header blob =
  let word off = word_of_bytes blob off in
  if word AC.hdr_magic <> AC.magic then fail "run_blob: bad magic (not a DOOM blob)";
  if word AC.hdr_version <> AC.version
  then fail "run_blob: blob version %d, want %d" (word AC.hdr_version) AC.version;
  if word AC.hdr_length <> Bytes.length blob
  then
    fail
      "run_blob: header length %d <> file length %d"
      (word AC.hdr_length)
      (Bytes.length blob);
  let sum = ref 0 in
  for w = AC.header_size / 4 to (Bytes.length blob / 4) - 1 do
    sum := (!sum + word (4 * w)) land 0xFFFF_FFFF
  done;
  if word AC.hdr_checksum <> !sum then fail "run_blob: checksum mismatch";
  if word AC.hdr_init = 0 || word AC.hdr_tick = 0
  then fail "run_blob: Init/Tick entry missing (0)"
;;

(* Run one entry to its return; returns R0. The clock state persists across calls,
   so the ms counter never rewinds. The step loop is the hot path (tens of billions
   of steps per timedemo): the profiling test is hoisted out of it, and the clock is
   a countdown in the loop arguments — no division or ref traffic per step. *)
let total_steps = ref 0
let sim_ms = ref 0
let ms_countdown = ref 0 (* steps to the next ms tick; armed on first use *)

let call_entry m name entry_addr ~r0 ~r1 =
  let regs = F.regs m in
  let stop =
    0xF0F0_F0F0
    (* sentinel return address: unreachable, word-aligned *)
  in
  regs.(15) <- stop;
  regs.(0) <- r0;
  regs.(1) <- r1;
  F.set_pc m (entry_addr / 4);
  let budget = !max_steps in
  let spm = !steps_per_ms in
  if !ms_countdown = 0 then ms_countdown := spm;
  let counts = !profile_counts in
  let profiling = Array.length counts > 0 in
  let base_word = !profile_base_word in
  let rec loop n cd =
    if F.pc m = stop / 4
    then (
      total_steps := !total_steps + n;
      ms_countdown := cd)
    else if n >= budget
    then fail "run_blob: %s exceeded %d steps (hung? raise -max-steps)" name budget
    else (
      let pc_before = F.pc m in
      F.single_step m;
      if profiling
      then (
        let w = pc_before - base_word in
        if w >= 0 && w < Array.length counts then counts.(w) <- counts.(w) + 1);
      let cd =
        if cd = 1
        then (
          incr sim_ms;
          M.set_time m !sim_ms;
          spm)
        else cd - 1
      in
      if F.pc m = pc_before
      then
        fail
          "run_blob: %s hit a self-loop trap at PC=0x%08X (see doom.blob.map)"
          name
          (pc_before * 4);
      loop (n + 1) cd)
  in
  loop 0 !ms_countdown;
  (F.regs m).(0)
;;

(* the raw fb window: 32*768 little-endian words, memory order (fb line 0 at
   the bottom) — byte-identical to the golden generator's fwrite of its array *)
let dump_raw m path =
  let words = M.fb_width m * M.fb_height m in
  let b = Bytes.create (words * 4) in
  for w = 0 to words - 1 do
    Bytes.set_int32_le b (4 * w) (Int32.of_int (M.framebuffer_word m w))
  done;
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_bytes oc b)
;;

(* doom.blob.map: "# ..." header lines, then "0xADDR name" per code symbol,
   ascending — a symbol owns [addr, next addr). *)
let parse_map path =
  let syms = ref [] in
  In_channel.with_open_text path (fun ic ->
    try
      while true do
        let line = input_line ic in
        if String.length line > 0 && line.[0] <> '#'
        then (
          match String.index_opt line ' ' with
          | Some sp ->
            let addr = int_of_string (String.sub line 0 sp) in
            let name = String.sub line (sp + 1) (String.length line - sp - 1) in
            syms := (addr, name) :: !syms
          | None -> ())
      done
    with
    | End_of_file -> ());
  Array.of_list (List.rev !syms)
;;

type klass =
  | Load
  | Store
  | Branch
  | Muldiv
  | Alu

let klass_of_word w =
  match Isa.decode w with
  | Isa.Load _ -> Load
  | Isa.Store _ -> Store
  | Isa.Branch _ -> Branch
  | Isa.Alu { op = Isa.Mul | Isa.Div; _ } -> Muldiv
  | Isa.Alu _ -> Alu
;;

let write_profile ~blob ~map_path ~ticks_run out =
  let counts = !profile_counts in
  let base_word = !profile_base_word in
  let syms = parse_map map_path in
  let n = Array.length syms in
  let s_instr = Array.make n 0
  and s_load = Array.make n 0
  and s_store = Array.make n 0
  and s_br = Array.make n 0
  and s_md = Array.make n 0 in
  let total = ref 0
  and t_load = ref 0
  and t_store = ref 0
  and t_br = ref 0
  and t_md = ref 0 in
  (* counts ascend by address, so the symbol cursor walks monotonically *)
  let si = ref 0 in
  Array.iteri
    (fun w c ->
       if c > 0
       then (
         let addr = (base_word + w) * 4 in
         while !si + 1 < n && fst syms.(!si + 1) <= addr do
           incr si
         done;
         let k = klass_of_word (word_of_bytes blob (addr - blob_base)) in
         s_instr.(!si) <- s_instr.(!si) + c;
         total := !total + c;
         let bump s t =
           s.(!si) <- s.(!si) + c;
           t := !t + c
         in
         match k with
         | Load -> bump s_load t_load
         | Store -> bump s_store t_store
         | Branch -> bump s_br t_br
         | Muldiv -> bump s_md t_md
         | Alu -> ()))
    counts;
  let order = Array.init n (fun i -> i) in
  Array.sort (fun a b -> compare s_instr.(b) s_instr.(a)) order;
  Out_channel.with_open_text out (fun oc ->
    let p fmt = Printf.fprintf oc fmt in
    let pct x = 100.0 *. float_of_int x /. float_of_int (max 1 !total) in
    p
      "# run_blob flat profile — %d instrs over %d ticks (%d instrs/tick)\n"
      !total
      ticks_run
      (!total / max 1 ticks_run);
    p
      "# mix: loads %.1f%%  stores %.1f%%  branches %.1f%%  mul/div %.1f%%  (mem total \
       %.1f%%)\n"
      (pct !t_load)
      (pct !t_store)
      (pct !t_br)
      (pct !t_md)
      (pct (!t_load + !t_store));
    p "#  rank    instrs    %%    cum%%   ld%%   st%%   br%%  name\n";
    let cum = ref 0 in
    Array.iteri
      (fun rank i ->
         if rank < 45 && s_instr.(i) > 0
         then (
           cum := !cum + s_instr.(i);
           let fp x = 100.0 *. float_of_int x /. float_of_int (max 1 s_instr.(i)) in
           p
             "%6d %9d %5.1f  %5.1f  %4.1f  %4.1f  %4.1f  %s\n"
             (rank + 1)
             s_instr.(i)
             (pct s_instr.(i))
             (pct !cum)
             (fp s_load.(i))
             (fp s_store.(i))
             (fp s_br.(i))
             (snd syms.(i))))
      order;
    (* call census: calls(f) = executions of f's entry word — exact when that
       word runs once per invocation; a prologue-less leaf opening with a loop
       puts the loop head ON the entry word, so read it as an upper bound *)
    let calls = Array.make n 0 in
    Array.iteri
      (fun i (addr, _) ->
         let w = (addr / 4) - base_word in
         if w >= 0 && w < Array.length counts then calls.(i) <- counts.(w))
      syms;
    let t_calls = Array.fold_left ( + ) 0 calls in
    p "#\n";
    p
      "# call census — calls = entry-word executions (upper bound: a loop head landing \
       on the entry word counts its iterations too)\n";
    p
      "# total calls %d (%d/tick); BL + B LNK glue = %d instrs = %.1f%% of all\n"
      t_calls
      (t_calls / max 1 ticks_run)
      (2 * t_calls)
      (pct (2 * t_calls));
    p "#  rank     calls   i/call     instrs    %%   name\n";
    let corder = Array.init n (fun i -> i) in
    Array.sort (fun a b -> compare calls.(b) calls.(a)) corder;
    Array.iteri
      (fun rank i ->
         if rank < 45 && calls.(i) > 0
         then
           p
             "%6d %9d %8.1f %10d %5.1f  %s\n"
             (rank + 1)
             calls.(i)
             (float_of_int s_instr.(i) /. float_of_int calls.(i))
             s_instr.(i)
             (pct s_instr.(i))
             (snd syms.(i)))
      corder);
  Printf.eprintf "run_blob: profile -> %s\n%!" out
;;

let dump_frame = Run_harness.dump_frame

let () =
  parse_args (List.tl (Array.to_list Sys.argv));
  if !dump_every < 0 then fail "run_blob: -dump-every %d: want >= 0" !dump_every;
  let blob_path, wad_path =
    match List.rev !inputs with
    | [ b; w ] -> b, w
    | _ -> fail "%s" usage
  in
  let blob = Bytes.of_string (read_file blob_path) in
  let wad = read_file wad_path in
  verify_header blob;
  if String.length wad > wad_cap
  then fail "run_blob: WAD %d bytes exceeds the §8 window %d" (String.length wad) wad_cap;
  let m = M.make () in
  let ram = F.ram m in
  load_image ram blob_base blob;
  let word off = word_of_bytes blob off in
  let bss_start = word AC.hdr_bss_base
  and bss_len = word AC.hdr_bss_length in
  for w = bss_start / 4 to ((bss_start + bss_len) / 4) - 1 do
    ram.(w) <- 0
  done;
  let wadb = Bytes.make ((String.length wad + 3) land lnot 3) '\000' in
  Bytes.blit_string wad 0 wadb 0 (String.length wad);
  load_image ram AC.wad_base wadb;
  for w = shared_base / 4 to ((shared_base + AC.shared_size) / 4) - 1 do
    ram.(w) <- 0
  done;
  ram.((shared_base + AC.shared_wad_len) / 4) <- String.length wad;
  if !hw then ram.((shared_base + AC.shared_present_flags) / 4) <- 1;
  (* NUL-terminated, as DOOM.Mod writes it *)
  if String.length !blob_args > 0
  then (
    if String.length !blob_args > 3000
    then fail "run_blob: -args longer than the §8 command-tail region";
    let tail = Bytes.make ((String.length !blob_args + 4) land lnot 3) '\000' in
    Bytes.blit_string !blob_args 0 tail 0 (String.length !blob_args);
    load_image ram (shared_base + AC.shared_cmd_tail) tail);
  M.set_serial
    m
    (Run_harness.tx_serial (fun b ->
       print_char (Char.chr (b land 0xFF));
       if b = 0x0A then flush stdout));
  M.set_time m 0;
  let status () = ram.((shared_base + AC.shared_status) / 4)
  and heartbeat () = ram.((shared_base + AC.shared_heartbeat) / 4) in
  Printf.eprintf "run_blob: Init...\n%!";
  let r =
    call_entry m "Init" (blob_base + word AC.hdr_init) ~r0:AC.wad_base ~r1:shared_base
  in
  flush stdout;
  Printf.eprintf
    "run_blob: Init -> %d (status %d), %d steps, %d sim-ms\n%!"
    (Run_harness.signed32 r)
    (Run_harness.signed32 (status ()))
    !total_steps
    !sim_ms;
  if r <> 0 then fail "run_blob: Init failed";
  let gametic_targets =
    if !dump_at = ""
    then []
    else
      List.map
        (fun s ->
           match int_of_string_opt (String.trim s) with
           | Some v -> v
           | None -> fail "run_blob: -dump-at: not an integer: %s" s)
        (String.split_on_char ',' !dump_at)
  in
  let dump_gametic g =
    let base = Printf.sprintf "frame_g%05d" g in
    dump_raw m (base ^ ".fbw");
    dump_frame m (base ^ ".pgm");
    Printf.eprintf
      "run_blob: gametic %d, fb %016Lx -> %s.fbw\n%!"
      g
      (H.framebuffer_hash m)
      base
  in
  (* did __dg_upload_thresholds land? The blue noise opens 15, 85, 28, 49, so the
     first word reads 311C550F *)
  if !hw
  then
    Printf.eprintf
      "run_blob: bn window after Init: %08X %08X %08X\n%!"
      (F.ram m).(AC.ht_threshold_base / 4)
      (F.ram m).((AC.ht_threshold_base + 4) / 4)
      (F.ram m).((AC.ht_threshold_base + 8) / 4);
  (* Create ran init plus one tic: the fb holds gametic 1 *)
  if List.mem 1 gametic_targets then dump_gametic 1;
  if !profile_out <> ""
  then (
    let code_start = blob_base + AC.header_size
    and bss_start = word AC.hdr_bss_base in
    profile_base_word := code_start / 4;
    profile_counts := Array.make ((bss_start - code_start) / 4) 0);
  let key_events =
    if !keys_spec = ""
    then []
    else
      List.map
        (fun s ->
           match String.split_on_char ':' (String.trim s) with
           | [ t; k; p ] ->
             (match int_of_string_opt t, int_of_string_opt k, int_of_string_opt p with
              | Some t, Some k, Some p -> t, p land 1 lor (k lsl 8)
              | _ -> fail "run_blob: -keys: not integers: %s" s)
           | _ -> fail "run_blob: -keys: want tick:doomkey:pressed, got %s" s)
        (String.split_on_char ',' !keys_spec)
  in
  if key_events <> [] && word AC.hdr_keyin = 0
  then fail "run_blob: -keys but no KeyIn entry";
  let frame = ref 0 in
  (try
     for t = 1 to !ticks do
       List.iter
         (fun (kt, ev) ->
            if kt = t
            then
              ignore (call_entry m "KeyIn" (blob_base + word AC.hdr_keyin) ~r0:ev ~r1:0))
         key_events;
       let r = call_entry m "Tick" (blob_base + word AC.hdr_tick) ~r0:0 ~r1:0 in
       flush stdout;
       (* under -timedemo, gametic = Ticks + 1 *)
       if List.mem (t + 1) gametic_targets then dump_gametic (t + 1);
       if
         gametic_targets = []
         && ((!dump_every > 0 && t mod !dump_every = 0) || t = !ticks || r <> 0)
       then (
         incr frame;
         let path = Printf.sprintf "frame_%04d.pgm" !frame in
         dump_frame m path;
         Printf.eprintf
           "run_blob: tick %d -> %d, heartbeat %d, %d sim-ms, fb %016Lx -> %s\n%!"
           t
           (Run_harness.signed32 r)
           (heartbeat ())
           !sim_ms
           (H.framebuffer_hash m)
           path);
       if r <> 0 || status () <> 0 then raise Exit
     done
   with
   | Exit -> ());
  Printf.eprintf
    "run_blob: done — status %d, heartbeat %d, %d total steps, %d sim-ms\n%!"
    (Run_harness.signed32 (status ()))
    (heartbeat ())
    !total_steps
    !sim_ms;
  if !profile_out <> ""
  then
    write_profile
      ~blob
      ~map_path:(blob_path ^ ".map")
      ~ticks_run:(heartbeat ())
      !profile_out
;;
