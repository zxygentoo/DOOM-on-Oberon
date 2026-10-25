(* run_sim — the blob on the cycle-accurate model: the board SoC under Cyclesim.

   The SoC is configured like the board bitstream (see [create]) and closed with the
   behavioural PSRAM widened to the full 16 MiB. The harness plays the loader: it
   writes the blob, the WAD and the SHARED page (+28 WAD length, +1024 command tail,
   +4 tick target) straight into the PSRAM model's byte lanes, then releases reset
   into the emit_rom boot ROM, which calls the blob's entries and reports through the
   SHARED page:

     +8  = 0xD00D0000 | (Init() & 0xFFFF) once Init returns; 0xD0E0D0E0 when done
     +16 = Tick's heartbeat (under -timedemo, gametic = heartbeat + 1)
     +12 = the blob's exit status

   Simulated time is the board's: the ms counter ticks every [clocks_per_ms] cycles,
   so cycles/tick is the real machine's cost, cache misses and all.

   Usage: run_sim [options] <doom.blob> <doom1.wad> <doomboot.rom>
     -ticks N          park after N Ticks (default 2; 0 = until the blob finishes)
     -args "TAIL"      the DOOM command tail, e.g. -args "-timedemo demo1"
     -fbw FILE         at the end, dump the fb window in the golden .fbw format
     -max-mcycles N    cycle cap in millions (default 4000)
     -hw               advertise the Halftone scanout; -fbw captures the panel
     -profile FILE     cycles by doom.blob.map symbol, from the first Tick
   Build and run on the OxCaml switch, with absolute paths: sim/README.md. *)

open Hardcaml
module Soc = Nexys4_board.Soc
module Cellram_model = Nexys4_board.Cellram_model

module I = struct
  type 'a t =
    { clock : 'a
    ; pclk : 'a [@bits 1]
    ; rst_n : 'a [@bits 1]
    ; miso : 'a [@bits 1]
    ; rxd : 'a [@bits 1]
    ; btn : 'a [@bits 4]
    ; sw : 'a [@bits 8]
    ; gpio_in : 'a [@bits 8]
    ; ps2c : 'a [@bits 1]
    ; ps2d : 'a [@bits 1]
    ; msclk : 'a [@bits 1]
    ; msdat : 'a [@bits 1]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { sclk : 'a [@bits 1]
    ; txd : 'a [@bits 1]
    ; hsync : 'a [@bits 1]
    ; vsync : 'a [@bits 1]
    ; rgb : 'a [@bits 6]
    }
  [@@deriving hardcaml]
end

(* the host's Board_tb wiring, with the PSRAM model widened to 16 MiB. Video DMA
   runs only under [hw] (served on-chip by Framebuf and Halftone); fb_bram is
   proven cycle-identical to the video-off build, so cycles/tick compare across
   the two. *)
let create ~hw ~contents (i : _ I.t) : _ O.t =
  let dq = Signal.wire 16 in
  let soc =
    Soc.create
      ~contents
      (* the bitstream's memory and multiplier knobs (the host's
         board/nexys-4/emit_verilog.ml), not the slow Soc defaults — but the
         clock is the 60 MHz build's, the one every sim number was measured on;
         the pinned host now ships 64 MHz (clocks_per_ms 64000) *)
      ~clocks_per_ms:60000
      ~read_cycles:6
      ~write_cycles:5
      ~fast_mul:true
      ~mul_stages:2
      ~icache:true
      ~lines_log2:12
      ~write_update:true
      ~write_buffer:true
      ~wbuf_depth:2
      ~video:hw
      ~fb_bram:hw
      ~halftone:hw
      { Soc.I.clock = i.clock
      ; pclk = i.pclk
      ; rst_n = i.rst_n
      ; miso = i.miso
      ; rxd = i.rxd
      ; btn = i.btn
      ; sw = i.sw
      ; gpio_in = i.gpio_in
      ; ps2c = i.ps2c
      ; ps2d = i.ps2d
      ; msclk = i.msclk
      ; msdat = i.msdat
      ; mem_dq_i = dq
      }
  in
  let m =
    Cellram_model.create
      ~addr_bits:23
      { Cellram_model.I.clock = i.clock
      ; mem_adr = soc.mem_adr
      ; mem_dq_o = soc.mem_dq_o
      ; ce_n = soc.ram_ce_n
      ; we_n = soc.ram_we_n
      ; ub_n = soc.ram_ub_n
      ; lb_n = soc.ram_lb_n
      }
  in
  Signal.assign dq m.mem_dq_i;
  { O.sclk = soc.sclk; txd = soc.txd; hsync = soc.hsync; vsync = soc.vsync; rgb = soc.rgb }
;;

module Sim = Cyclesim.With_interface (I) (O)

(* ABI §8 values restated: abi_constants lives in the other dune root *)
let shared_base = 0x300000
let blob_base = 0x100000
let wad_base = 0xA00000
let fb_base_word = 0xE7F00 / 4
let fb_words = 32 * 768
let init_marker = 0xD00D_0000
let done_marker = 0xD0E0_D0E0

let fail fmt =
  Printf.ksprintf
    (fun s ->
       prerr_endline s;
       exit 1)
    fmt
;;

let read_file p =
  try In_channel.with_open_bin p In_channel.input_all with
  | Sys_error e -> fail "run_sim: %s" e
;;

let ticks = ref 2
let blob_args = ref ""
let fbw = ref ""
let max_mcycles = ref 4000
let chunk = 500_000
let profile_out = ref ""
let hw = ref false
let inputs = ref []

let rec parse = function
  | "-ticks" :: n :: r ->
    ticks := int_of_string n;
    parse r
  | "-args" :: s :: r ->
    blob_args := s;
    parse r
  | "-fbw" :: p :: r ->
    fbw := p;
    parse r
  | "-max-mcycles" :: n :: r ->
    max_mcycles := int_of_string n;
    parse r
  | "-hw" :: r ->
    (* SHARED +544 bit 0: the blob presents through Halftone, and -fbw captures
       what the panel shows (see the capture at the end) *)
    hw := true;
    parse r
  | "-profile" :: p :: r ->
    (* samples the core's pc every cycle from the first Tick on (where run_blob
       -profile starts too) and charges the cycle to that address: a stalled
       instruction holds pc, so stall cycles land where they are paid. Divided
       by run_blob's per-symbol instruction counts, it gives per-function CPI. *)
    profile_out := p;
    parse r
  | a :: r ->
    inputs := a :: !inputs;
    parse r
  | [] -> ()
;;

(* doom.blob.map: "# ..." headers, then "0xADDR name" per code symbol, ascending
   (run_blob's parser) *)
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

let write_profile ~map_path ~counts ~base_word ~outside ~ticks_run out =
  let syms = parse_map map_path in
  let n = Array.length syms in
  let s_cyc = Array.make n 0 in
  let total = ref 0 in
  let si = ref 0 in
  Array.iteri
    (fun w c ->
       if c > 0
       then (
         let addr = (base_word + w) * 4 in
         while !si + 1 < n && fst syms.(!si + 1) <= addr do
           incr si
         done;
         s_cyc.(!si) <- s_cyc.(!si) + c;
         total := !total + c))
    counts;
  let order = Array.init n (fun i -> i) in
  Array.sort (fun a b -> compare s_cyc.(b) s_cyc.(a)) order;
  Out_channel.with_open_text out (fun oc ->
    let p fmt = Printf.fprintf oc fmt in
    let pct x = 100.0 *. float_of_int x /. float_of_int (max 1 (!total + outside)) in
    p
      "# run_sim cycle profile — %d cycles in blob code over %d ticks (%d cyc/tick), \
       %d (%.1f%%) outside the blob\n"
      !total
      ticks_run
      (!total / max 1 ticks_run)
      outside
      (pct outside);
    p "#  rank    cycles     %%    cum%%  name\n";
    let cum = ref 0 in
    Array.iteri
      (fun rank i ->
         if rank < 45 && s_cyc.(i) > 0
         then (
           cum := !cum + s_cyc.(i);
           p
             "%6d %9d  %5.1f  %5.1f  %s\n"
             (rank + 1)
             s_cyc.(i)
             (pct s_cyc.(i))
             (pct !cum)
             (snd syms.(i))))
      order);
  Printf.eprintf "run_sim: cycle profile -> %s\n%!" out
;;

let () =
  parse (List.tl (Array.to_list Sys.argv));
  let blob_path, wad_path, rom_path =
    match List.rev !inputs with
    | [ b; w; r ] -> b, w, r
    | _ -> fail "usage: run_sim [options] <doom.blob> <doom1.wad> <doomboot.rom>"
  in
  let blob = read_file blob_path
  and wad = read_file wad_path
  and rom = read_file rom_path in
  let rom_words =
    Array.init (String.length rom / 4) (fun i ->
      Int32.to_int (String.get_int32_le rom (4 * i)) land 0xFFFF_FFFF)
  in
  let sim =
    Sim.create ~config:Cyclesim.Config.trace_all (create ~hw:!hw ~contents:rom_words)
  in
  let i = Cyclesim.inputs sim in
  let cram_lo = Cyclesim.lookup_mem_by_name sim "cram_lo" |> Option.get
  and cram_hi = Cyclesim.lookup_mem_by_name sim "cram_hi" |> Option.get in
  (* poke: byte [a] into the right lane; halfword address a/2 *)
  let poke_byte a v =
    let mem = if a land 1 = 0 then cram_lo else cram_hi in
    Cyclesim.Memory.of_int mem ~address:(a lsr 1) v
  and peek_word w =
    let bl k = Cyclesim.Memory.to_int cram_lo ~address:k
    and bh k = Cyclesim.Memory.to_int cram_hi ~address:k in
    bl (2 * w) lor (bh (2 * w) lsl 8) lor (bl ((2 * w) + 1) lsl 16) lor (bh ((2 * w) + 1) lsl 24)
  in
  let poke_string base s = String.iteri (fun k c -> poke_byte (base + k) (Char.code c)) s in
  poke_string blob_base blob;
  poke_string wad_base wad;
  (* the model's memory starts zeroed: no SHARED clearing, and the tail's NUL is free *)
  let wl = String.length wad in
  poke_byte (shared_base + 28) (wl land 0xFF);
  poke_byte (shared_base + 29) ((wl lsr 8) land 0xFF);
  poke_byte (shared_base + 30) ((wl lsr 16) land 0xFF);
  poke_byte (shared_base + 31) ((wl lsr 24) land 0xFF);
  if String.length !blob_args > 0 then poke_string (shared_base + 1024) !blob_args;
  (* the ROM's tick target *)
  poke_byte (shared_base + 4) (!ticks land 0xFF);
  poke_byte (shared_base + 5) ((!ticks lsr 8) land 0xFF);
  poke_byte (shared_base + 6) ((!ticks lsr 16) land 0xFF);
  poke_byte (shared_base + 7) ((!ticks lsr 24) land 0xFF);
  if !hw then poke_byte (shared_base + 544) 1;
  (* idle inputs; reset for a few cycles *)
  i.pclk := Bits.gnd;
  i.miso := Bits.vdd;
  i.rxd := Bits.vdd;
  i.ps2c := Bits.vdd;
  i.ps2d := Bits.vdd;
  i.msclk := Bits.vdd;
  i.msdat := Bits.vdd;
  i.btn := Bits.zero 4;
  i.sw := Bits.zero 8;
  i.gpio_in := Bits.zero 8;
  i.rst_n := Bits.gnd;
  for _ = 1 to 8 do
    Cyclesim.cycle sim
  done;
  i.rst_n := Bits.vdd;
  let cycles = ref 0 in
  let shared k = peek_word ((shared_base + k) / 4) in
  let init_done = ref false in
  let init_cycles = ref 0 in
  let last_hb = ref 0 in
  let tick_marks = ref [] (* (heartbeat, cycles) at each observed change *) in
  (* -profile state: the traced core PC (a 22-bit WORD address), a counter per
     blob code word (header word +12 = bss start, absolute), an outside bucket *)
  let pc_node =
    if !profile_out = ""
    then None
    else (
      match Cyclesim.lookup_node_or_reg_by_name sim "pc" with
      | Some n -> Some n
      | None -> fail "run_sim: -profile: no traced node named \"pc\"")
  in
  let base_word = (blob_base + 64) / 4 in
  let bss_start =
    Int32.to_int (String.get_int32_le blob 12) land 0xFFFF_FFFF
  in
  let counts = Array.make (max 1 ((bss_start / 4) - base_word)) 0 in
  let outside = ref 0 in
  let t0 = Unix.gettimeofday () in
  (try
     while !cycles < !max_mcycles * 1_000_000 do
       (match pc_node with
        | Some node when !init_done ->
          for _ = 1 to chunk do
            Cyclesim.cycle sim;
            let w = Cyclesim.Node.to_int node - base_word in
            if w >= 0 && w < Array.length counts
            then counts.(w) <- counts.(w) + 1
            else incr outside
          done
        | _ ->
          for _ = 1 to chunk do
            Cyclesim.cycle sim
          done);
       cycles := !cycles + chunk;
       let m = shared 8
       and hb = shared 16 in
       if !cycles mod (20 * chunk) = 0
       then
         Printf.eprintf
           "run_sim: ... %d Mcyc, hb %d (%.2f Mcyc/s)\n%!"
           (!cycles / 1_000_000)
           hb
           (float_of_int !cycles /. 1e6 /. (Unix.gettimeofday () -. t0));
       if (not !init_done) && m land 0xFFFF_0000 = init_marker
       then (
         init_done := true;
         init_cycles := !cycles;
         Printf.eprintf
           "run_sim: Init -> %d at ~%d Mcyc (%.0f s wall, %.2f Mcyc/s)\n%!"
           (m land 0xFFFF)
           (!cycles / 1_000_000)
           (Unix.gettimeofday () -. t0)
           (float_of_int !cycles /. 1e6 /. (Unix.gettimeofday () -. t0));
         if m land 0xFFFF <> 0 then raise Exit);
       if hb <> !last_hb
       then (
         last_hb := hb;
         tick_marks := (hb, !cycles) :: !tick_marks;
         Printf.eprintf
           "run_sim: heartbeat %d at ~%d Mcyc (status %d)\n%!"
           hb
           (!cycles / 1_000_000)
           (shared 12));
       if m = done_marker then raise Exit
     done;
     Printf.eprintf "run_sim: cycle cap reached (%d Mcyc)\n%!" !max_mcycles
   with
   | Exit -> ());
  (* report cycles/tick over the observed window *)
  (match List.rev !tick_marks with
   | (h0, c0) :: rest when rest <> [] ->
     let hn, cn = List.hd !tick_marks in
     if hn > h0
     then
       Printf.eprintf
         "run_sim: %d ticks over %d Mcyc -> ~%d cycles/tick (~%.1f fps at 60 MHz)\n%!"
         (hn - h0)
         ((cn - c0) / 1_000_000)
         ((cn - c0) / (hn - h0))
         (60.0e6 /. float_of_int ((cn - c0) / (hn - h0)))
   | _ -> ());
  Printf.eprintf
    "run_sim: done — %d Mcyc total, heartbeat %d, status %d, marker %08X\n%!"
    (!cycles / 1_000_000)
    (shared 16)
    (shared 12)
    (shared 8);
  if !fbw <> ""
  then
    if !hw
    then (
      (* Reconstruct the frame the panel shows. The machine is parked in the
         ROM's self-loop while the raster free-runs (Cyclesim steps the pclk
         logic 1:1 with clk), so one full scan (~1.1 M cycles) visits all 24576
         visible words. Each ht_ack completes the word in ht_word; which word is
         tracked off the SoC-level vidreq/vidadr wires: the FSM accepts only
         when idle and acks 12 cycles later, well inside the raster's
         ~29.5-cycle request spacing, so an ack pairs with the last request
         seen. (A probe register inside Halftone would be dead logic, which
         Cyclesim prunes.) The file is the golden .fbw: span rows 256..1023
         ascending = the screen bottom-up. *)
      let probe n =
        match Cyclesim.lookup_node_or_reg_by_name sim n with
        | Some x -> x
        | None -> fail "run_sim: -hw: no traced node named %S" n
      in
      let ack = probe "ht_ack"
      and req = probe "vidreq"
      and adr = probe "vidadr"
      and wordn = probe "ht_word" in
      let org = 0xDFF00 / 4 in
      let pending = ref 0 in
      let words = Array.make (32 * 768) (-1) in
      let seen = ref 0 in
      let cyc = ref 0 in
      while !seen < 32 * 768 && !cyc < 4_000_000 do
        Cyclesim.cycle sim;
        incr cyc;
        if Cyclesim.Node.to_int req = 1 then pending := Cyclesim.Node.to_int adr;
        if Cyclesim.Node.to_int ack = 1
        then (
          let woff = !pending - org in
          let rr = woff lsr 5
          and c = woff land 31 in
          if rr >= 256 && rr < 1024
          then (
            let idx = ((rr - 256) * 32) + c in
            if words.(idx) < 0 then incr seen;
            words.(idx) <- Cyclesim.Node.to_int wordn))
      done;
      Printf.eprintf
        "run_sim: -hw scanout capture: %d/24576 words over %d cycles\n%!"
        !seen
        !cyc;
      let b = Bytes.create (fb_words * 4) in
      for w = 0 to fb_words - 1 do
        Bytes.set_int32_le b (4 * w) (Int32.of_int (max words.(w) 0))
      done;
      Out_channel.with_open_bin !fbw (fun oc -> Out_channel.output_bytes oc b);
      Printf.eprintf "run_sim: scanout fb -> %s\n%!" !fbw)
    else (
      let b = Bytes.create (fb_words * 4) in
      for w = 0 to fb_words - 1 do
        Bytes.set_int32_le b (4 * w) (Int32.of_int (peek_word (fb_base_word + w)))
      done;
      Out_channel.with_open_bin !fbw (fun oc -> Out_channel.output_bytes oc b);
      Printf.eprintf "run_sim: fb -> %s\n%!" !fbw);
  if !profile_out <> ""
  then
    write_profile
      ~map_path:(blob_path ^ ".map")
      ~counts
      ~base_word
      ~outside:!outside
      ~ticks_run:(shared 16)
      !profile_out
;;
