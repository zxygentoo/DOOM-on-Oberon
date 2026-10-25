(* run_dsk — boot a .dsk on the emulator in-process and drive the booted system from
   a script: raw PS/2 bytes (as the SDL frontend encodes them, fake-shift wrappers and
   all), middle-clicks (which run Oberon commands), SHARED-page probes (status and
   key-ring indices, read from RAM) and PGM dumps. Where run_blob -keys exercises the
   blob's input path, run_dsk exercises DOOM.Mod's on the booted OS.

   Time is simulated (frame i = i/60 s), so a script reproduces exactly. The UART is
   captured to a file. The disk is written in place — pass a copy.

   Usage: run_dsk [options] <image.dsk>   (options: [usage], or -help)
   Click y counts from the top, as read off a dumped PGM. -htdump reads the Halftone
   pixel window (ABI §11: 320×200 bytes at 0x310000, top row first) as an 8-bit PGM:
   the emulator has no scanout, but the window is plain RAM, and a client with an
   identity LUT (Mandel) dumps as a viewable grayscale frame. *)

module M = Emu.Risc
module F = Emu.Risc.For_tests
module H = Emu.Headless
module AC = Abi_constants

let fps = H.fps
let cpu_hz = H.cpu_hz
let ht_w = 320 (* the DOOM client's halftone window geometry (ABI §11) *)
let ht_h = 200
let fail = Run_harness.fail

let usage =
  "usage: run_dsk [options] <image.dsk>   (the disk is written in place)\n\
  \  -seconds N             simulated seconds to run (default 30)\n\
  \  -serial-log FILE       UART capture (default run_dsk-uart.log)\n\
  \  -ps2 \"ms:HEXBYTES,...\" raw PS/2 bytes at a simulated time\n\
  \  -click \"ms:x:ytop,...\" middle-click at screen coords, y from the top\n\
  \  -probe \"ms,...\"        print the SHARED status and key-ring indices\n\
  \  -dump \"ms:name,...\"    framebuffer -> run_dsk_<name>.pgm\n\
  \  -htdump \"ms:name,...\"  Halftone pixel window -> run_dsk_<name>.pgm"
;;

let seconds = ref 30
let serial_log = ref "run_dsk-uart.log"
let ps2_spec = ref ""
let click_spec = ref ""
let probe_spec = ref ""
let dump_spec = ref ""
let htdump_spec = ref ""
let inputs = ref []

let rec parse_args = function
  | "-seconds" :: n :: rest ->
    (match int_of_string_opt n with
     | Some v ->
       seconds := v;
       parse_args rest
     | None -> fail "run_dsk: not an integer: %s" n)
  | "-serial-log" :: f :: rest ->
    serial_log := f;
    parse_args rest
  | "-ps2" :: s :: rest ->
    ps2_spec := s;
    parse_args rest
  | "-click" :: s :: rest ->
    click_spec := s;
    parse_args rest
  | "-probe" :: s :: rest ->
    probe_spec := s;
    parse_args rest
  | "-dump" :: s :: rest ->
    dump_spec := s;
    parse_args rest
  | "-htdump" :: s :: rest ->
    htdump_spec := s;
    parse_args rest
  | ("-help" | "--help") :: _ ->
    print_endline usage;
    exit 0
  | a :: _ when String.length a > 1 && a.[0] = '-' ->
    fail "run_dsk: unknown flag, or a flag missing its value: %s\n%s" a usage
  | a :: rest ->
    inputs := a :: !inputs;
    parse_args rest
  | [] -> ()
;;

let split c s = List.filter (fun x -> x <> "") (String.split_on_char c (String.trim s))

let int_of s =
  match int_of_string_opt (String.trim s) with
  | Some v -> v
  | None -> fail "run_dsk: not an integer: %s" s
;;

let bytes_of_hex s =
  let n = String.length s in
  if n = 0 || n land 1 <> 0 then fail "run_dsk: empty or odd-length hex string: %s" s;
  Bytes.init (n / 2) (fun i ->
    let pair = String.sub s (2 * i) 2 in
    match int_of_string_opt ("0x" ^ pair) with
    | Some b -> Char.chr b
    | None -> fail "run_dsk: bad hex byte %S in %s" pair s)
;;

(* one scheduled action, fired when simulated ms passes its time *)
type action =
  | Ps2 of bytes
  | Click of int * int (* x, y-from-top: move + middle press *)
  | Release (* middle button up, auto-scheduled 400 ms after a Click *)
  | Probe
  | Dump of string
  | Htdump of string

let schedule () =
  let acts = ref [] in
  let add ms a = acts := (ms, a) :: !acts in
  List.iter
    (fun e ->
       match split ':' e with
       | [ ms; hex ] -> add (int_of ms) (Ps2 (bytes_of_hex hex))
       | _ -> fail "run_dsk: -ps2 wants ms:HEXBYTES, got %s" e)
    (split ',' !ps2_spec);
  List.iter
    (fun e ->
       match split ':' e with
       | [ ms; x; y ] -> add (int_of ms) (Click (int_of x, int_of y))
       | _ -> fail "run_dsk: -click wants ms:x:ytop, got %s" e)
    (split ',' !click_spec);
  List.iter (fun e -> add (int_of e) Probe) (split ',' !probe_spec);
  List.iter
    (fun e ->
       match split ':' e with
       | [ ms; name ] -> add (int_of ms) (Dump name)
       | _ -> fail "run_dsk: -dump wants ms:name, got %s" e)
    (split ',' !dump_spec);
  List.iter
    (fun e ->
       match split ':' e with
       | [ ms; name ] -> add (int_of ms) (Htdump name)
       | _ -> fail "run_dsk: -htdump wants ms:name, got %s" e)
    (split ',' !htdump_spec);
  List.sort compare !acts
;;

(* PGM P5: the halftone pixel window, already top-down byte-per-pixel *)
let dump_htframe m path =
  let ram = F.ram m in
  Out_channel.with_open_bin path (fun oc ->
    Printf.fprintf oc "P5\n%d %d\n255\n" ht_w ht_h;
    for i = 0 to (ht_w * ht_h) - 1 do
      let b = (ram.((AC.ht_pixel_base + i) / 4) lsr (8 * (i land 3))) land 0xFF in
      Out_channel.output_char oc (Char.chr b)
    done)
;;

let dump_frame = Run_harness.dump_frame

let () =
  parse_args (List.tl (Array.to_list Sys.argv));
  let dsk =
    match !inputs with
    | [ d ] -> d
    | _ -> fail "%s" usage
  in
  if not (Sys.file_exists dsk) then fail "run_dsk: no such disk: %s" dsk;
  let m = M.make () in
  M.set_spi m 1 (Emu.Disk.to_spi (Emu.Disk.create (Some dsk)));
  let uart = Out_channel.open_bin !serial_log in
  M.set_serial
    m
    (Run_harness.tx_serial (fun b ->
       Out_channel.output_char uart (Char.chr (b land 0xFF));
       Out_channel.flush uart));
  let acts = ref (schedule ()) in
  let ram = F.ram m in
  let probe ms =
    let w off = ram.((AC.shared_base + off) / 4) in
    Printf.printf
      "run_dsk: %6d ms  status %d  ring head %d tail %d  fb %016Lx\n%!"
      ms
      (Run_harness.signed32 (w AC.shared_status))
      (w AC.shared_ring_head)
      (w AC.shared_ring_tail)
      (H.framebuffer_hash m)
  in
  let frames = !seconds * fps in
  for i = 0 to frames - 1 do
    let now = (i + 1) * 1000 / fps in
    M.set_time m now;
    M.run m (cpu_hz / fps);
    let rec fire () =
      match !acts with
      | (ms, a) :: rest when ms <= now ->
        acts := rest;
        (match a with
         | Ps2 b ->
           M.keyboard_input m b;
           Printf.printf "run_dsk: %6d ms  ps2 %d byte(s)\n%!" ms (Bytes.length b)
         | Click (x, ytop) ->
           (* held 400 ms: Oberon polls the mouse once per loop pass, and with
              DOOM in a viewer a pass includes a whole game tick (~125 sim-ms), so
              a short pulse can fall between polls. Commands fire on release, so
              the long hold is still one click. *)
           M.mouse_moved m x (M.fb_height m - 1 - ytop);
           M.mouse_button m 2 true;
           acts := List.sort compare ((ms + 400, Release) :: !acts);
           Printf.printf "run_dsk: %6d ms  middle-click (%d, %d top)\n%!" ms x ytop
         | Release -> M.mouse_button m 2 false
         | Probe -> probe ms
         | Dump name ->
           let path = Printf.sprintf "run_dsk_%s.pgm" name in
           dump_frame m path;
           Printf.printf "run_dsk: %6d ms  frame -> %s\n%!" ms path
         | Htdump name ->
           let path = Printf.sprintf "run_dsk_%s.pgm" name in
           dump_htframe m path;
           Printf.printf "run_dsk: %6d ms  htframe -> %s\n%!" ms path);
        fire ()
      | _ -> ()
    in
    fire ()
  done;
  probe (frames * 1000 / fps);
  Out_channel.close uart
;;
