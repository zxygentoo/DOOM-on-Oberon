(* emit_rom — the boot ROM run_sim boots: the stub's calling side, for Cyclesim.

   run_sim preloads blob, WAD and SHARED page into the PSRAM model, so the ROM only
   calls: R0/R1 = WAD and SHARED, BL Init, then BL Tick until done, with the entry
   offsets read from the blob's §7 header at run time. It talks to run_sim through
   two SHARED words no loader uses:

     +8 (out)  0xD00D0000 | (Init() & 0xFFFF)   after Init returns
               0xD0E0D0E0                        when Init or Tick returns nonzero
                                                 or the target is reached; the ROM
                                                 then parks, the fb frozen
     +4 (in)   tick target; 0 = run until Tick returns nonzero

   Tick heartbeats +16 itself, and +12 is the blob's exit status (§8).

   No stack: the only calls are to the thunks, which bring their own. R6-R11 hold the
   ROM's state across them — the thunks save and restore those (test_blob proves it).

   Usage: emit_rom [-o out.rom]   (default doomboot.rom; raw little-endian words) *)

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
