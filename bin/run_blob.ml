(* run_blob — the 1d emulator harness: play DOOM.Mod's stub against the real blob.

   Loads doom.blob at BLOB_BASE and the WAD at WAD_BASE (ABI §8), verifies the §7
   header and zeroes bss, sets up the SHARED page (+28 = WAD length), attaches a UART
   console (the blob's printf arrives on stdout), and drives Init/Tick through the
   crt0 thunks exactly as test_blob rehearsed — plus a deterministic synthetic ms
   clock (the ms-counter MMIO advances every [steps_per_ms] instructions, default
   44 000 ≈ 60 MHz / CPI 1.37, so simulated time roughly models the real machine and
   fps numbers mean something). Frames dump as PGM (1024×768, fb bottom-up flipped,
   bit 0 = leftmost, 1 = white) plus the Headless FNV hash — the visual-golden anchor.

   A PC that doesn't advance across a step is a self-loop — doomcc's trap for refused
   or undefined symbols — reported with the address for a doom.blob.map lookup.

   Usage: run_blob [-ticks N] [-dump-every N] [-steps-per-ms N] [-max-steps N]
                  <doom.blob> <doom1.wad> *)

module M = Emu.Risc
module F = Emu.Risc.For_tests
module Isa = Emu.Risc5_isa
module H = Emu.Headless
module AC = Abi_constants

(* ABI §8, the himem layout — the constants page (lib/abi_constants.ml). *)
let blob_base = AC.blob_base
let shared_base = AC.shared_base
let wad_cap = AC.wad_window_end - AC.wad_base
let fail = Run_harness.fail
let read_file = Run_harness.read_file

(* ---- args ---- *)

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
    (* the DOOM command tail, written verbatim to SHARED +1024 (ABI §8) before
       Init — e.g. -args "-timedemo demo1". Under -timedemo the engine runs
       singletics (one gametic per Tick, one render each), so the heartbeat IS
       the gametic counter and -dump-every dumps at exact gametics; the run
       finishes through G_CheckDemoStatus's I_Error ("timed N gametics ..." on
       the console, SHARED status negative) — that unwind is the SUCCESS path. *)
    blob_args := s;
    parse_args rest
  | "-profile" :: p :: rest ->
    (* the emulator flat profile (the 1d perf campaign's Amdahl instrument):
       count PC hits per code word during the Tick loop (Init excluded — the
       frame is what matters), then aggregate by doom.blob.map symbol ranges
       and weight the STATIC per-word opcode classes by the dynamic counts —
       the exact dynamic instruction mix at zero per-step decode cost. *)
    profile_out := p;
    parse_args rest
  | "-keys" :: s :: rest ->
    (* scripted input: comma list of tick:doomkey:pressed (all decimal) —
       each event goes through the real KeyIn entry (ev = pressed | key<<8,
       ABI §7) just before that Tick, so the whole ring/responder/menu path
       is drivable headlessly, e.g. menu quit: 27 Esc, 113 'q', 121 'y' *)
    keys_spec := s;
    parse_args rest
  | "-hw" :: rest ->
    (* feat/halftone: advertise the hardware scanout (SHARED +544 bit 0,
       ABI.md §11). The emulator models no Halftone — the window is
       plain RAM and nothing reads the mode bit — but the BLOB forks on the
       flag: DG_DrawFrame drops the dither for the LUT upload, so -profile /
       instruction counts measure the hw-path workload. Frame dumps are
       meaningless in this mode (the mono fb is never written). *)
    hw := true;
    parse_args rest
  | "-dump-at" :: s :: rest ->
    (* comma list of GAMETICS (needs -args "-timedemo demo1": singletics makes
       gametic = tick count + 1, so both this harness and the host golden
       generator key dumps on counted Ticks — no game-memory access). Dumps
       frame_gNNNNN.fbw — the raw fb window, 32*768 LE words in memory order —
       the format bin/doom_golden.c writes as golden_gNNNNN.fbw;
       cmp(1) of the pair is the oracle's verdict. A .pgm rides along for
       eyeballs. Pick gametics past the demo-start wipe (>= 100). *)
    dump_at := s;
    parse_args rest
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

(* ---- the machine, loaded the way the stub loads it ---- *)

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

(* Run one crt0 entry to its B LNK, advancing the synthetic clock; returns R0.
   [total_steps] / [ms_countdown] persist across calls so the ms counter never
   rewinds. The step loop is THE harness hot path (tens of billions of steps over
   a timedemo), so the per-step work stays branch-cheap: the profiling test is a
   bool hoisted out of the loop, and the ms clock is a countdown threaded through
   the loop arguments — no division, no ref traffic per step. *)
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

(* ---- the flat profile report ---- *)

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
      order);
  Printf.eprintf "run_blob: profile -> %s\n%!" out
;;

let dump_frame = Run_harness.dump_frame

let () =
  parse_args (List.tl (Array.to_list Sys.argv));
  let blob_path, wad_path =
    match List.rev !inputs with
    | [ b; w ] -> b, w
    | _ -> fail "usage: run_blob [options] <doom.blob> <doom1.wad>"
  in
  let blob = Bytes.of_string (read_file blob_path) in
  let wad = read_file wad_path in
  verify_header blob;
  if String.length wad > wad_cap
  then fail "run_blob: WAD %d bytes exceeds the §8 window %d" (String.length wad) wad_cap;
  let m = M.make () in
  let ram = F.ram m in
  (* the stub's obligations: image at BLOB_BASE, bss zeroed per the header *)
  load_image ram blob_base blob;
  let word off = word_of_bytes blob off in
  let bss_start = word AC.hdr_bss_base
  and bss_len = word AC.hdr_bss_length in
  for w = bss_start / 4 to ((bss_start + bss_len) / 4) - 1 do
    ram.(w) <- 0
  done;
  (* WAD into himem (padded tail rides the pre-zeroed RAM) *)
  let wadb = Bytes.make ((String.length wad + 3) land lnot 3) '\000' in
  Bytes.blit_string wad 0 wadb 0 (String.length wad);
  load_image ram AC.wad_base wadb;
  (* SHARED page: zeroed, then the WAD length (§8 +28) *)
  for w = shared_base / 4 to ((shared_base + AC.shared_size) / 4) - 1 do
    ram.(w) <- 0
  done;
  ram.((shared_base + AC.shared_wad_len) / 4) <- String.length wad;
  if !hw then ram.((shared_base + AC.shared_present_flags) / 4) <- 1;
  (* the command tail (§8 +1024): raw bytes + NUL, exactly as the stub will *)
  if String.length !blob_args > 0
  then (
    if String.length !blob_args > 3000
    then fail "run_blob: -args longer than the §8 command-tail region";
    let tail = Bytes.make ((String.length !blob_args + 4) land lnot 3) '\000' in
    Bytes.blit_string !blob_args 0 tail 0 (String.length !blob_args);
    load_image ram (shared_base + AC.shared_cmd_tail) tail);
  (* UART console: printf -> stdout *)
  M.set_serial
    m
    (Run_harness.tx_serial (fun b ->
       print_char (Char.chr (b land 0xFF));
       if b = 0x0A then flush stdout));
  M.set_time m 0;
  let status () = ram.((shared_base + AC.shared_status) / 4)
  and heartbeat () = ram.((shared_base + AC.shared_heartbeat) / 4) in
  (* ---- Init(wad_addr, cfg_addr) ---- *)
  Printf.eprintf "run_blob: Init...\n%!";
  let r =
    call_entry m "Init" (blob_base + word AC.hdr_init) ~r0:AC.wad_base ~r1:shared_base
  in
  flush stdout;
  Printf.eprintf
    "run_blob: Init -> %d (status %d), %d steps, %d sim-ms\n%!"
    r
    (status ())
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
  (* post-Init the fb holds gametic 1's render (Create runs init + one tic) *)
  (* -hw probe: the Halftone threshold window's first words after Init — did the
     blob's __dg_upload_thresholds land? (v2 raw upload: expected 0x30E000 =
     311C550F for the DOOM blue noise, bytes 15, 85, 28, 49 verbatim) *)
  if !hw
  then
    Printf.eprintf
      "run_blob: bn window after Init: %08X %08X %08X\n%!"
      (F.ram m).(AC.ht_threshold_base / 4)
      (F.ram m).((AC.ht_threshold_base + 4) / 4)
      (F.ram m).((AC.ht_threshold_base + 8) / 4);
  if List.mem 1 gametic_targets then dump_gametic 1;
  (* -profile: count from the first Tick on (Init excluded — frames are the cost) *)
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
  (* ---- Tick loop ---- *)
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
       (* singletics under -timedemo: gametic = tick count + 1 *)
       if List.mem (t + 1) gametic_targets then dump_gametic (t + 1);
       if gametic_targets = [] && (t mod !dump_every = 0 || t = !ticks || r <> 0)
       then (
         incr frame;
         let path = Printf.sprintf "frame_%04d.pgm" !frame in
         dump_frame m path;
         Printf.eprintf
           "run_blob: tick %d -> %d, heartbeat %d, %d sim-ms, fb %016Lx -> %s\n%!"
           t
           r
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
    (status ())
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
