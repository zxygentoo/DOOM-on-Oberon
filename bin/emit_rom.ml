(* emit_rom — the Cyclesim boot ROM stub (AGENT.md 1d, the sim leg).

   The cycle-accurate model boots from its 512-word ROM (reset PC = ROM word 0, byte
   0xFFE000); the sim harness preloads blob + WAD + SHARED page directly into the PSRAM
   model, so the ROM's only job is the stub's calling side: point R0/R1 at the WAD and
   the SHARED page, BL the blob's crt0 entries (read from the §7 header at runtime — no
   baked offsets), and report progress through the SHARED page for the harness to poll:

     SHARED+8 (the reserved flags word — the sim harness contract):
       0xD00D0000 | (Init() & 0xFFFF)   after Init returns
       0xD0E0D0E0                        after Tick returns nonzero, or the tick
                                         target is reached (fb frozen exactly there)
     SHARED+4 (in): tick target — park after this many Ticks; 0 = run forever.
     SHARED+16 is Tick's own heartbeat; SHARED+12 the blob's exit status (§8).

   The stub needs no stack (its only calls are the thunks, which own theirs) and makes
   no MMIO accesses; R6-R11 hold its state across calls — the crt0 thunks save and
   restore them, so they survive by the very contract test_blob proves.

   Usage: emit_rom [-o doomboot.rom]  — raw little-endian u32 words. *)

module R = Emu.Risc5_isa
module L = Doomcc_core.Linker
module AC = Abi_constants
open Doomcc_core.Asm

let rom_base = 0xFFE000 (* reset vector: ROM word 0 *)

let bl_reg c : L.frag =
  ins (R.Branch { cond = R.True; neg = false; link = true; target = R.To_reg c })
;;

let l_loop = 0
let l_done = 1

let stub : L.obj =
  { name = "emit_rom"
  ; frags =
      load_const2 6 AC.blob_base (* R6 = BLOB_BASE *)
      @ [ ldw 8 6 AC.hdr_init (* R8 = header Init offset *)
        ; alu R.Add 8 8 (R.Reg 6) (* ... absolute *)
        ; ldw 7 6 AC.hdr_tick (* R7 = header Tick offset *)
        ; alu R.Add 7 7 (R.Reg 6)
        ]
      @ load_const2 9 AC.shared_base (* R9 = SHARED *)
      @ load_const2 0 AC.wad_base (* Init arg 0: wad_addr *)
      @ [ alu R.Mov 1 0 (R.Reg 9) (* Init arg 1: cfg = SHARED *)
        ; bl_reg 8 (* Init(wad, shared) *)
        ]
      @ load_const2 2 0xD00D_0000
      @ [ alu R.And 3 0 (R.Imm 0xFFFF) (* marker | (result & 0xFFFF) *)
        ; alu R.Ior 3 3 (R.Reg 2)
        ; stw 3 9 8 (* SHARED+8 = Init marker *)
        ; alu R.Sub 2 0 (R.Imm 0) (* flags from Init result *)
        ; L.Bcc (R.Eq, true, l_done) (* nonzero -> done *)
        ; L.Label l_loop
        ; bl_reg 7 (* Tick() — heartbeats SHARED+16 itself *)
        ; alu R.Sub 2 0 (R.Imm 0)
        ; L.Bcc (R.Eq, true, l_done) (* nonzero -> demo over *)
        ; ldw 2 9 4 (* tick target (0 = forever) *)
        ; alu R.Sub 2 2 (R.Imm 0)
        ; L.Bcc (R.Eq, false, l_loop) (* no target -> keep ticking *)
        ; ldw 3 9 AC.shared_heartbeat (* heartbeat *)
        ; alu R.Sub 4 3 (R.Reg 2)
        ; L.Bcc (R.Lt, false, l_loop) (* hb < target -> keep ticking *)
        ; L.Label l_done
        ]
      @ load_const2 2 0xD0E0_D0E0
      @ [ stw 2 9 8 (* SHARED+8 = done marker *); L.Label 2; L.Jmp 2 (* park *) ]
  }
;;

let () =
  let out =
    match Array.to_list Sys.argv with
    | [ _ ] -> "doomboot.rom"
    | [ _; "-o"; p ] -> p
    | _ ->
      prerr_endline "usage: emit_rom [-o out.rom]";
      exit 1
  in
  let image = L.link ~code_base:rom_base [ stub ] in
  let words = List.map R.encode image.L.code in
  let b = Bytes.create (4 * List.length words) in
  List.iteri (fun i w -> Bytes.set_int32_le b (4 * i) (Int32.of_int w)) words;
  Out_channel.with_open_bin out (fun oc -> Out_channel.output_bytes oc b);
  Printf.printf
    "emit_rom: %d words -> %s (linked at 0x%06X)\n"
    (List.length words)
    out
    rom_base
;;
