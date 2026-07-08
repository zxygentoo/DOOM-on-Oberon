(* doom_sim — DOOM on the cycle-accurate model (AGENT.md 1d, the Cyclesim leg).

   The board SoC (icache on, board PSRAM timing) closed with Cellram_model widened to
   the full 16 MiB (addr_bits 23 — the first full-SoC exercise of 2a's himem decode).
   The harness plays the loader: pokes doom.blob, doom1.wad, and the SHARED page
   (+28 WAD length, +1024 command tail) straight into the PSRAM model's byte lanes
   before releasing reset, and boots the doomboot ROM stub (bin/doomboot.ml), which
   calls the blob's crt0 entries and reports through the SHARED page:

     +8  = 0xD00D0000 | (Init() & 0xFFFF)  once Init returns; 0xD0E0D0E0 when done
     +16 = Tick's heartbeat (under -timedemo: singletics, heartbeat = gametic - 1)
     +12 = the blob's exit status

   Simulated time is real time: the board ms counter ticks every 60 000 cycles, so
   cycles/tick IS the 60 MHz machine's honest cost, cache misses and all.

   Output: progress per chunk (cycles, heartbeat), cycles-per-tick over the run, and
   -fbw dumps the fb window in the golden format (32*768 LE words) for cmp against
   host/doomgeneric_golden.c and doomrun.

   Build & run (the ox switch — see sim/dune):
     opam exec --switch=5.2.0+ox -- dune exec --root sim ./doom_sim.exe -- \
       ../doom.blob ../doom1.wad ../doomboot.rom -args "-timedemo demo1" \
       -ticks 2 -fbw ../sim_g00002.fbw *)

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

(* the Board_tb wiring, with the himem-wide PSRAM model and no video traffic *)
let create ~contents (i : _ I.t) : _ O.t =
  let dq = Signal.wire 16 in
  let soc =
    Soc.create
      ~contents
      (* the SHIPPED bitstream config (emit_verilog.ml) — measure the real
         machine, not the poor-performance soc.ml defaults: 60 MHz ms clock,
         Phase-9 pipelined DSP multipliers, the full 10a-10d memory arc
         (icache + write-update snoop + depth-2 write buffer). fb_bram is
         moot with ~video:false (no DMA to serve); rc/wc are the rc=6 trade. *)
      ~clocks_per_ms:60000
      ~read_cycles:6
      ~write_cycles:5
      ~fast_mul:true
      ~mul_stages:2
      ~icache:true
      ~write_update:true
      ~write_buffer:true
      ~wbuf_depth:2
      ~video:false
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

(* ---- ABI §8 constants + the SHARED sim contract ---- *)
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
  | Sys_error e -> fail "doom_sim: %s" e
;;

(* ---- args ---- *)
let ticks = ref 2
let blob_args = ref ""
let fbw = ref ""
let max_mcycles = ref 4000
let chunk = 500_000
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
  | a :: r ->
    inputs := a :: !inputs;
    parse r
  | [] -> ()
;;

let () =
  parse (List.tl (Array.to_list Sys.argv));
  let blob_path, wad_path, rom_path =
    match List.rev !inputs with
    | [ b; w; r ] -> b, w, r
    | _ -> fail "usage: doom_sim [options] <doom.blob> <doom1.wad> <doomboot.rom>"
  in
  let blob = read_file blob_path
  and wad = read_file wad_path
  and rom = read_file rom_path in
  let rom_words =
    Array.init (String.length rom / 4) (fun i ->
      Int32.to_int (String.get_int32_le rom (4 * i)) land 0xFFFF_FFFF)
  in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all (create ~contents:rom_words) in
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
  (* SHARED: model memory is born zeroed; write the WAD length + command tail *)
  let wl = String.length wad in
  poke_byte (shared_base + 28) (wl land 0xFF);
  poke_byte (shared_base + 29) ((wl lsr 8) land 0xFF);
  poke_byte (shared_base + 30) ((wl lsr 16) land 0xFF);
  poke_byte (shared_base + 31) ((wl lsr 24) land 0xFF);
  if String.length !blob_args > 0 then poke_string (shared_base + 1024) !blob_args;
  (* the stub's tick target (SHARED+4): it parks the machine there, fb frozen *)
  poke_byte (shared_base + 4) (!ticks land 0xFF);
  poke_byte (shared_base + 5) ((!ticks lsr 8) land 0xFF);
  poke_byte (shared_base + 6) ((!ticks lsr 16) land 0xFF);
  poke_byte (shared_base + 7) ((!ticks lsr 24) land 0xFF);
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
  let t0 = Unix.gettimeofday () in
  (try
     while !cycles < !max_mcycles * 1_000_000 do
       for _ = 1 to chunk do
         Cyclesim.cycle sim
       done;
       cycles := !cycles + chunk;
       let m = shared 8
       and hb = shared 16 in
       if !cycles mod (20 * chunk) = 0
       then
         Printf.eprintf
           "doom_sim: ... %d Mcyc, hb %d (%.2f Mcyc/s)\n%!"
           (!cycles / 1_000_000)
           hb
           (float_of_int !cycles /. 1e6 /. (Unix.gettimeofday () -. t0));
       if (not !init_done) && m land 0xFFFF_0000 = init_marker
       then (
         init_done := true;
         init_cycles := !cycles;
         Printf.eprintf
           "doom_sim: Init -> %d at ~%d Mcyc (%.0f s wall, %.2f Mcyc/s)\n%!"
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
           "doom_sim: heartbeat %d at ~%d Mcyc (status %d)\n%!"
           hb
           (!cycles / 1_000_000)
           (shared 12));
       if m = done_marker then raise Exit
     done;
     Printf.eprintf "doom_sim: cycle cap reached (%d Mcyc)\n%!" !max_mcycles
   with
   | Exit -> ());
  (* report cycles/tick over the observed window *)
  (match List.rev !tick_marks with
   | (h0, c0) :: rest when rest <> [] ->
     let hn, cn = List.hd !tick_marks in
     if hn > h0
     then
       Printf.eprintf
         "doom_sim: %d ticks over %d Mcyc -> ~%d cycles/tick (~%.1f fps at 60 MHz)\n%!"
         (hn - h0)
         ((cn - c0) / 1_000_000)
         ((cn - c0) / (hn - h0))
         (60.0e6 /. float_of_int ((cn - c0) / (hn - h0)))
   | _ -> ());
  Printf.eprintf
    "doom_sim: done — %d Mcyc total, heartbeat %d, status %d, marker %08X\n%!"
    (!cycles / 1_000_000)
    (shared 16)
    (shared 12)
    (shared 8);
  if !fbw <> ""
  then (
    let b = Bytes.create (fb_words * 4) in
    for w = 0 to fb_words - 1 do
      Bytes.set_int32_le b (4 * w) (Int32.of_int (peek_word (fb_base_word + w)))
    done;
    Out_channel.with_open_bin !fbw (fun oc -> Out_channel.output_bytes oc b);
    Printf.eprintf "doom_sim: fb -> %s\n%!" !fbw)
;;
