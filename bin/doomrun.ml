(* doomrun — the 1d emulator harness: play DOOM.Mod's stub against the real blob.

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

   Usage: doomrun [-ticks N] [-dump-every N] [-steps-per-ms N] [-max-steps N]
                  <doom.blob> <doom1.wad> *)

module M = Emu.Risc
module F = Emu.Risc.For_tests
module H = Emu.Headless

(* ABI §8, the himem layout. *)
let blob_base = 0x100000
let shared_base = 0x300000
let shared_size = 0x1000
let wad_base = 0xA00000
let wad_cap = 0x401000 (* the §8 window: 4 MiB + one page (the real WAD overruns 4 MiB) *)
let fb_word_base = 0xE7F00 / 4
let fb_words = 32 (* 1024 px / 32 *)
let fb_lines = 768

let fail fmt =
  Printf.ksprintf
    (fun s ->
       prerr_endline s;
       exit 1)
    fmt
;;

let read_file path =
  try In_channel.with_open_bin path In_channel.input_all with
  | Sys_error e -> fail "doomrun: %s" e
;;

(* ---- args ---- *)

let ticks = ref 10
let dump_every = ref 1
let steps_per_ms = ref 44_000
let max_steps = ref 2_000_000_000
let inputs = ref []

let rec parse_args = function
  | "-ticks" :: n :: rest -> set_int ticks n rest
  | "-dump-every" :: n :: rest -> set_int dump_every n rest
  | "-steps-per-ms" :: n :: rest -> set_int steps_per_ms n rest
  | "-max-steps" :: n :: rest -> set_int max_steps n rest
  | a :: rest ->
    inputs := a :: !inputs;
    parse_args rest
  | [] -> ()

and set_int r n rest =
  match int_of_string_opt n with
  | Some v ->
    r := v;
    parse_args rest
  | None -> fail "doomrun: not an integer: %s" n
;;

(* ---- the machine, loaded the way the stub loads it ---- *)

let word_of_bytes b off = Int32.to_int (Bytes.get_int32_le b off) land 0xFFFF_FFFF

let load_image ram base (b : bytes) =
  let n = Bytes.length b in
  if n land 3 <> 0 then fail "doomrun: image length %d not word-aligned" n;
  for w = 0 to (n / 4) - 1 do
    ram.((base / 4) + w) <- word_of_bytes b (4 * w)
  done
;;

let verify_header blob =
  let word off = word_of_bytes blob off in
  if word 0 <> 0x4D4F4F44 then fail "doomrun: bad magic (not a DOOM blob)";
  if word 4 <> 1 then fail "doomrun: blob version %d, want 1" (word 4);
  if word 8 <> Bytes.length blob
  then fail "doomrun: header length %d <> file length %d" (word 8) (Bytes.length blob);
  let sum = ref 0 in
  for w = 16 to (Bytes.length blob / 4) - 1 do
    sum := (!sum + word (4 * w)) land 0xFFFF_FFFF
  done;
  if word 32 <> !sum then fail "doomrun: checksum mismatch";
  if word 20 = 0 || word 24 = 0 then fail "doomrun: Init/Tick entry missing (0)"
;;

(* Run one crt0 entry to its B LNK, advancing the synthetic clock; returns R0.
   [total_steps] persists across calls so the ms counter never rewinds. *)
let total_steps = ref 0
let sim_ms = ref 0

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
  let rec loop n =
    if F.pc m = stop / 4
    then ()
    else if n >= budget
    then fail "doomrun: %s exceeded %d steps (hung? raise -max-steps)" name budget
    else (
      let pc_before = F.pc m in
      F.single_step m;
      incr total_steps;
      if !total_steps mod !steps_per_ms = 0
      then (
        incr sim_ms;
        M.set_time m !sim_ms);
      if F.pc m = pc_before
      then
        fail
          "doomrun: %s hit a self-loop trap at PC=0x%08X (see doom.blob.map)"
          name
          (pc_before * 4);
      loop (n + 1))
  in
  loop 0;
  (F.regs m).(0)
;;

(* ---- framebuffer dump: PGM P5, fb bottom-up flipped, bit 0 leftmost ---- *)

let dump_frame m path =
  let ram = F.ram m in
  Out_channel.with_open_bin path (fun oc ->
    Printf.fprintf oc "P5\n%d %d\n255\n" (fb_words * 32) fb_lines;
    for y = 0 to fb_lines - 1 do
      let line = fb_lines - 1 - y in
      for wx = 0 to fb_words - 1 do
        let w = ram.(fb_word_base + (line * fb_words) + wx) in
        for bit = 0 to 31 do
          Out_channel.output_char oc (if (w lsr bit) land 1 = 1 then '\255' else '\000')
        done
      done
    done)
;;

let () =
  parse_args (List.tl (Array.to_list Sys.argv));
  let blob_path, wad_path =
    match List.rev !inputs with
    | [ b; w ] -> b, w
    | _ -> fail "usage: doomrun [options] <doom.blob> <doom1.wad>"
  in
  let blob = Bytes.of_string (read_file blob_path) in
  let wad = read_file wad_path in
  verify_header blob;
  if String.length wad > wad_cap
  then fail "doomrun: WAD %d bytes exceeds the §8 window %d" (String.length wad) wad_cap;
  let m = M.make () in
  let ram = F.ram m in
  (* the stub's obligations: image at BLOB_BASE, bss zeroed per the header *)
  load_image ram blob_base blob;
  let word off = word_of_bytes blob off in
  let bss_start = word 12
  and bss_len = word 16 in
  for w = bss_start / 4 to ((bss_start + bss_len) / 4) - 1 do
    ram.(w) <- 0
  done;
  (* WAD into himem (padded tail rides the pre-zeroed RAM) *)
  let wadb = Bytes.make ((String.length wad + 3) land lnot 3) '\000' in
  Bytes.blit_string wad 0 wadb 0 (String.length wad);
  load_image ram wad_base wadb;
  (* SHARED page: zeroed, then the WAD length (§8 +28) *)
  for w = shared_base / 4 to ((shared_base + shared_size) / 4) - 1 do
    ram.(w) <- 0
  done;
  ram.((shared_base + 28) / 4) <- String.length wad;
  (* UART console: tx always ready (status bit 1), rx never; printf -> stdout *)
  M.set_serial
    m
    { Emu.Io.serial_read_status = (fun () -> 2)
    ; serial_read_data = (fun () -> 0)
    ; serial_write_data =
        (fun b ->
          print_char (Char.chr (b land 0xFF));
          if b = 0x0A then flush stdout)
    };
  M.set_time m 0;
  let status () = ram.((shared_base + 12) / 4)
  and heartbeat () = ram.((shared_base + 16) / 4) in
  (* ---- Init(wad_addr, cfg_addr) ---- *)
  Printf.eprintf "doomrun: Init...\n%!";
  let r = call_entry m "Init" (blob_base + word 20) ~r0:wad_base ~r1:shared_base in
  flush stdout;
  Printf.eprintf
    "doomrun: Init -> %d (status %d), %d steps, %d sim-ms\n%!"
    r
    (status ())
    !total_steps
    !sim_ms;
  if r <> 0 then fail "doomrun: Init failed";
  (* ---- Tick loop ---- *)
  let frame = ref 0 in
  (try
     for t = 1 to !ticks do
       let r = call_entry m "Tick" (blob_base + word 24) ~r0:0 ~r1:0 in
       flush stdout;
       if t mod !dump_every = 0 || t = !ticks || r <> 0
       then (
         incr frame;
         let path = Printf.sprintf "frame_%04d.pgm" !frame in
         dump_frame m path;
         Printf.eprintf
           "doomrun: tick %d -> %d, heartbeat %d, %d sim-ms, fb %016Lx -> %s\n%!"
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
    "doomrun: done — status %d, heartbeat %d, %d total steps, %d sim-ms\n%!"
    (status ())
    (heartbeat ())
    !total_steps
    !sim_ms
;;
