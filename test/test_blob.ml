(* The blob envelope and boundary protocol, end to end: compile a small program, emit
   the blob with a crt0 thunk as its Init entry, then play DOOM.Mod's stub in the
   emulator at the real ABI §8 addresses — load the file, verify the header, zero the
   bss it names, and BL the header's entry.

   The loader sets nothing but what a stub's BL would: R0 (the arg), LNK, and PC. DB
   and SP belong to the thunk, and R6-R14 arrive as Oberon's world — seeded with
   sentinels, asserted intact after the excursion into C. *)

module Isa = Emu.Risc5_isa
module M = Emu.Risc
open Doomcc_core

let base = 0x100000 (* BLOB_BASE, ABI §8 *)
let stack_top = 0x300000 (* STACK_TOP, ABI §8 *)
let max_steps = 1_000_000

(* the program: data global · bss global · fn-ptr Code reloc · string Data reloc *)
let src =
  "int gd = 5; int gb; int inc(int x){ return x + 1; } int (*gfp)(int) = inc; char *msg \
   = \"hey\"; int ent(int x){ return gfp(gd + x) + gb + msg[1]; }"
;;

(* ent(x) = inc(5 + x) + 0 + 'e' — gb MUST read 0: the stub's bss zeroing at work *)
let expected x = x + 6 + Char.code 'e'

let () =
  (* compile, lay out and emit as doomcc does *)
  let file = Frontend.parse_string ~name:"blob" src in
  let globals = Globals.from_file file in
  let objs = List.map (Fundec.compile ~globals) (Frontend.fundecs file) @ Runtime.objs in
  (* Crt0.size is a constant, so the code section is sized before the layout exists *)
  let code_words =
    List.fold_left (fun a o -> a + Linker.code_size o) 0 objs + Crt0.size
  in
  let data_size = globals.Globals.data_size in
  let bss_size = Bytes.length globals.Globals.image - data_size in
  assert (bss_size >= 4) (* gb really is in the bss tail *);
  (* the save area rides at the end of bss, which the stub zeroes *)
  let layout =
    Blob.layout ~base ~code_words ~data_size ~bss_size:(bss_size + Crt0.save_area_size)
  in
  let thunk =
    Crt0.thunk
      ~name:"__crt0_Init"
      ~entry:"ent"
      ~save_area:(layout.Blob.bss_base + bss_size)
      ~stack_top
      ~data_base:layout.Blob.data_base
  in
  let image = Linker.link ~code_base:layout.Blob.code_base (objs @ [ thunk ]) in
  let data = Bytes.sub globals.Globals.image 0 data_size in
  List.iter
    (fun (off, target) ->
       let v =
         match target with
         | Globals.Data t -> layout.Blob.data_base + t
         | Globals.Code name -> Linker.sym_addr image name
       in
       Bytes.set_int32_le data off (Int32.of_int v))
    globals.Globals.relocs;
  let entry_off = Linker.sym_addr image "__crt0_Init" - base in
  let blob = Blob.emit ~layout ~code:image.Linker.code ~data ~entries:(entry_off, 0, 0) in
  (* the header, checked from the file bytes alone *)
  let word off = Int32.to_int (Bytes.get_int32_le blob off) land 0xFFFF_FFFF in
  assert (word 0 = 0x4D4F4F44) (* "DOOM" LE *);
  assert (word 4 = 1);
  assert (word 8 = Bytes.length blob);
  assert (word 12 = layout.Blob.bss_base);
  assert (word 16 = bss_size + Crt0.save_area_size) (* the save area is stub-zeroed too *);
  assert (word 20 = entry_off);
  assert (word 24 = 0 && word 28 = 0) (* no Tick/KeyIn thunks *);
  let sum = ref 0 in
  for w = 16 to (Bytes.length blob / 4) - 1 do
    sum := (!sum + word (4 * w)) land 0xFFFF_FFFF
  done;
  assert (word 32 = !sum);
  for off = 36 to 63 do
    assert (Bytes.get blob off = '\000') (* reserved tail *)
  done;
  (* play the stub *)
  let run x =
    let m = M.make () in
    let ram = M.For_tests.ram m in
    for w = 0 to (Bytes.length blob / 4) - 1 do
      ram.((base / 4) + w)
      <- Int32.to_int (Bytes.get_int32_le blob (4 * w)) land 0xFFFF_FFFF
    done;
    (* poison the bss first, so the zeroing is load-bearing: gb would read
       0xAAAAAAAA if the stub skipped it *)
    let bss_start = word 12
    and bss_len = word 16 in
    for w = bss_start / 4 to ((bss_start + bss_len) / 4) - 1 do
      ram.(w) <- 0xAAAA_AAAA
    done;
    for w = bss_start / 4 to ((bss_start + bss_len) / 4) - 1 do
      ram.(w) <- 0
    done;
    let regs = M.For_tests.regs m in
    (* Oberon's world: no DB or SP from us — the thunk owns the switch. R15 is the
       stub's BL return address. *)
    List.iter (fun r -> regs.(r) <- 0xCAFE_0000 lor r) [ 6; 7; 8; 9; 10; 11; 12; 13; 14 ];
    let stop = (base + word 8) / 4 in
    regs.(15) <- stop * 4;
    regs.(0) <- x land 0xFFFF_FFFF;
    M.For_tests.set_pc m ((base + word 20) / 4) (* the header's entry offset *);
    let rec loop n =
      if M.For_tests.pc m = stop
      then ()
      else if n >= max_steps
      then failwith "test_blob: step cap exceeded"
      else (
        M.For_tests.single_step m;
        loop (n + 1))
    in
    loop 0;
    let regs = M.For_tests.regs m in
    (* R6-R14 restored bit-exact *)
    List.iter
      (fun r ->
         if regs.(r) <> 0xCAFE_0000 lor r
         then
           failwith
             (Printf.sprintf
                "test_blob: Oberon's R%d clobbered across the thunk: %08x"
                r
                regs.(r)))
      [ 6; 7; 8; 9; 10; 11; 12; 13; 14 ];
    regs.(0)
  in
  let fails = ref 0 in
  List.iter
    (fun x ->
       let got = run x
       and want = expected x land 0xFFFF_FFFF in
       if got <> want
       then (
         incr fails;
         Printf.printf "  MISMATCH ent(%d): got %08x want %08x\n" x got want))
    [ 0; 1; 7; 100; -6; 1000 ];
  Printf.printf
    "blob envelope: header verified (magic/version/lengths/entry/checksum), %d runs via \
     the header's entry, %d failures\n"
    6
    !fails;
  if !fails > 0 then exit 1
;;

(* the linker refuses a second object under a taken name *)
let () =
  let ret = Isa.Branch { cond = True; neg = false; link = false; target = To_reg 15 } in
  let f = { Linker.name = "f"; frags = [ Linker.Ins ret ] } in
  match Linker.link ~code_base:base [ f; f ] with
  | exception Invalid_argument msg -> Printf.printf "link: duplicate refused (%s)\n" msg
  | _ -> failwith "test_blob: Linker.link accepted a duplicate symbol"
;;
