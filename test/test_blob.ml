(* The blob envelope, end to end (3b.2, ABI §7/§8): compile a small program, emit the
   blob file through Blob, then play DOOM.Mod's stub — load the file bytes at BLOB_BASE,
   verify the header (magic, version, lengths, checksum), zero the bss range the header
   names, and run an entry — in the vendored emulator. The emulator models Oberon's 1 MB
   RAM (the 24-bit himem widening is a pending vendor patch), so the test's base is
   0x40000 instead of the real 0x100000; the layout math is identical, only the constant
   differs.

   One dishonesty, stated: DB is set from the layout here, because the crt0 thunks that
   own the DB/SP world switch (ABI §7) are the NEXT slice — the header carries no data
   base on purpose (the thunk bakes it in at link time). When the thunks land, this
   loader stops touching DB and the test tightens. *)

module Isa = Emu.Risc5_isa
module M = Emu.Risc
open Doomcc_core

let base =
  0x40000 (* test BLOB_BASE: inside the emulator's 1 MB (real machine: 0x100000) *)
;;

let stack_top = 0x70000
let max_steps = 1_000_000

(* the program: data global · bss global · fn-ptr Code reloc · string Data reloc *)
let src =
  "int gd = 5; int gb; int inc(int x){ return x + 1; } int (*gfp)(int) = inc; char *msg \
   = \"hey\"; int ent(int x){ return gfp(gd + x) + gb + msg[1]; }"
;;

(* ent(x) = inc(5 + x) + 0 + 'e' — gb MUST read 0: the stub's bss zeroing at work *)
let expected x = x + 6 + Char.code 'e'

let () =
  (* ---- compile + lay out + emit, exactly as doomcc does ---- *)
  let file = Frontend.parse_string ~name:"blob" src in
  let globals = Globals.from_file file in
  let objs = List.map (Fundec.compile ~globals) (Frontend.fundecs file) @ Runtime.objs in
  let code_words = List.fold_left (fun a o -> a + Linker.code_size o) 0 objs in
  let data_size = globals.Globals.data_size in
  let bss_size = Bytes.length globals.Globals.image - data_size in
  assert (bss_size >= 4) (* gb really is in the bss tail *);
  let layout = Blob.layout ~base ~code_words ~data_size ~bss_size in
  let image = Linker.link ~code_base:layout.Blob.code_base objs in
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
  let entry_off = Linker.sym_addr image "ent" - base in
  let blob = Blob.emit ~layout ~code:image.Linker.code ~data ~entries:(entry_off, 0, 0) in
  (* ---- verify the frozen v1 header (ABI §7) from the FILE BYTES alone ---- *)
  let word off = Int32.to_int (Bytes.get_int32_le blob off) land 0xFFFF_FFFF in
  assert (word 0 = 0x4D4F4F44) (* "DOOM" LE *);
  assert (word 4 = 1) (* version *);
  assert (word 8 = Bytes.length blob) (* image length = the file *);
  assert (word 12 = layout.Blob.bss_base);
  assert (word 16 = bss_size);
  assert (word 20 = entry_off);
  assert (word 24 = 0 && word 28 = 0) (* Tick/KeyIn: no thunks yet *);
  let sum = ref 0 in
  for w = 16 to (Bytes.length blob / 4) - 1 do
    sum := (!sum + word (4 * w)) land 0xFFFF_FFFF
  done;
  assert (word 32 = !sum) (* checksum over the words after the header *);
  for off = 36 to 63 do
    assert (Bytes.get blob off = '\000') (* reserved tail *)
  done;
  (* ---- play stub: load at base, poison then zero bss per the header, run ent ---- *)
  let run x =
    let m = M.make () in
    let ram = M.For_tests.ram m in
    for w = 0 to (Bytes.length blob / 4) - 1 do
      ram.((base / 4) + w)
      <- Int32.to_int (Bytes.get_int32_le blob (4 * w)) land 0xFFFF_FFFF
    done;
    (* the loader owes the blob a zeroed bss (ABI §7): poison first so the zeroing is
       load-bearing — gb would read 0xAAAAAAAA if the stub skipped it *)
    let bss_start = word 12
    and bss_len = word 16 in
    for w = bss_start / 4 to ((bss_start + bss_len) / 4) - 1 do
      ram.(w) <- 0xAAAA_AAAA
    done;
    for w = bss_start / 4 to ((bss_start + bss_len) / 4) - 1 do
      ram.(w) <- 0
    done;
    let regs = M.For_tests.regs m in
    regs.(13) <- layout.Blob.data_base (* DB — the thunk's job, next slice *);
    regs.(14) <- stack_top;
    let stop = (base + word 8) / 4 in
    regs.(15) <- stop * 4 (* LNK sentinel: returning from ent lands on stop *);
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
    M.For_tests.regs m |> fun r -> r.(0)
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
