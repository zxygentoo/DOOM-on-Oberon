(* dskrun — boot a .dsk on the vendored emulator IN-PROCESS and drive the booted
   system with a deterministic script: raw PS/2 bytes (exactly what the SDL
   frontend encodes — fake-shift wrappers and all), mouse clicks (middle-click
   invokes Oberon commands, so no serial orchestration), SHARED-page probes
   (ABI §8: status / key-ring head / tail read straight from RAM), and PGM
   frame dumps. The on-system complement of doomrun's -keys: doomrun proves
   the blob's input path, dskrun proves DOOM.Mod's PollKeys and the whole
   stub on the real booted OS.

   The machine is paced by SIMULATED time (frame i = i/60 s), so scripts are
   reproducible and the run goes as fast as the host allows. The UART (blob
   printf) is captured to a log file. The disk is written IN PLACE — pass a
   copy.

   Usage: dskrun [-seconds N] [-serial-log FILE]
                 [-ps2 "ms:HEXBYTES,..."] [-click "ms:x:ytop,..."]
                 [-probe "ms,..."] [-dump "ms:name,..."] <image.dsk>

   Click coordinates are screen coords with y from the TOP (what you read off
   a dumped PGM); the Oberon flip happens here. *)

module M = Emu.Risc
module F = Emu.Risc.For_tests
module H = Emu.Headless

let fps = 60
let cpu_hz = 25_000_000
let shared_base = 0x300000
let fb_word_base = 0xE7F00 / 4
let fb_words = 32
let fb_lines = 768

let fail fmt =
  Printf.ksprintf
    (fun s ->
       prerr_endline s;
       exit 1)
    fmt
;;

(* ---- args ---- *)

let seconds = ref 30
let serial_log = ref "dskrun-uart.log"
let ps2_spec = ref ""
let click_spec = ref ""
let probe_spec = ref ""
let dump_spec = ref ""
let inputs = ref []

let rec parse_args = function
  | "-seconds" :: n :: rest ->
    (match int_of_string_opt n with
     | Some v ->
       seconds := v;
       parse_args rest
     | None -> fail "dskrun: not an integer: %s" n)
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
  | a :: rest ->
    inputs := a :: !inputs;
    parse_args rest
  | [] -> ()
;;

let split c s = List.filter (fun x -> x <> "") (String.split_on_char c (String.trim s))

let int_of s =
  match int_of_string_opt (String.trim s) with
  | Some v -> v
  | None -> fail "dskrun: not an integer: %s" s
;;

let bytes_of_hex s =
  let n = String.length s in
  if n = 0 || n land 1 <> 0 then fail "dskrun: odd hex string: %s" s;
  Bytes.init (n / 2) (fun i -> Char.chr (int_of_string ("0x" ^ String.sub s (2 * i) 2)))
;;

(* one scheduled action, fired when simulated ms passes its time *)
type action =
  | Ps2 of bytes
  | Click of int * int (* x, y-from-top: move + middle press *)
  | Release (* middle button up, auto-scheduled 50 ms after a Click *)
  | Probe
  | Dump of string

let schedule () =
  let acts = ref [] in
  let add ms a = acts := (ms, a) :: !acts in
  List.iter
    (fun e ->
       match split ':' e with
       | [ ms; hex ] -> add (int_of ms) (Ps2 (bytes_of_hex hex))
       | _ -> fail "dskrun: -ps2 wants ms:HEXBYTES, got %s" e)
    (split ',' !ps2_spec);
  List.iter
    (fun e ->
       match split ':' e with
       | [ ms; x; y ] -> add (int_of ms) (Click (int_of x, int_of y))
       | _ -> fail "dskrun: -click wants ms:x:ytop, got %s" e)
    (split ',' !click_spec);
  List.iter (fun e -> add (int_of e) Probe) (split ',' !probe_spec);
  List.iter
    (fun e ->
       match split ':' e with
       | [ ms; name ] -> add (int_of ms) (Dump name)
       | _ -> fail "dskrun: -dump wants ms:name, got %s" e)
    (split ',' !dump_spec);
  List.sort compare !acts
;;

(* PGM P5: fb bottom-up flipped so the file reads top-down, bit 0 leftmost *)
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
  let dsk =
    match !inputs with
    | [ d ] -> d
    | _ -> fail "usage: dskrun [options] <image.dsk>  (disk is written in place)"
  in
  if not (Sys.file_exists dsk) then fail "dskrun: no such disk: %s" dsk;
  let m = M.make () in
  M.set_spi m 1 (Emu.Disk.to_spi (Emu.Disk.create (Some dsk)));
  let uart = Out_channel.open_bin !serial_log in
  M.set_serial
    m
    { Emu.Io.serial_read_status = (fun () -> 2) (* tx always ready, rx never *)
    ; serial_read_data = (fun () -> 0)
    ; serial_write_data =
        (fun b ->
          Out_channel.output_char uart (Char.chr (b land 0xFF));
          Out_channel.flush uart)
    };
  let acts = ref (schedule ()) in
  let ram = F.ram m in
  let probe ms =
    let w off = ram.((shared_base + off) / 4) in
    Printf.printf
      "dskrun: %6d ms  status %d  ring head %d tail %d  fb %016Lx\n%!"
      ms
      (w 12)
      (w 20)
      (w 24)
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
           Printf.printf "dskrun: %6d ms  ps2 %d byte(s)\n%!" ms (Bytes.length b)
         | Click (x, ytop) ->
           (* move + middle press (SDL button 2); Oberon polls the mouse word,
              so the press persists until the auto-scheduled Release *)
           M.mouse_moved m x (fb_lines - 1 - ytop);
           M.mouse_button m 2 true;
           acts := List.sort compare ((ms + 50, Release) :: !acts);
           Printf.printf "dskrun: %6d ms  middle-click (%d, %d top)\n%!" ms x ytop
         | Release -> M.mouse_button m 2 false
         | Probe -> probe ms
         | Dump name ->
           let path = Printf.sprintf "dskrun_%s.pgm" name in
           dump_frame m path;
           Printf.printf "dskrun: %6d ms  frame -> %s\n%!" ms path);
        fire ()
      | _ -> ()
    in
    fire ()
  done;
  probe (frames * 1000 / fps);
  Out_channel.close uart
;;
