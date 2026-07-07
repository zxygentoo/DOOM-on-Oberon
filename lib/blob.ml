(* The blob envelope (ABI §7/§8). See blob.mli. The header is FROZEN v1 — offsets 0-35
   locked; growth only in the reserved tail, anything else bumps the version byte. *)

module R = Emu.Risc5_isa

let header_size = 64
let magic = 0x4D4F4F44 (* "DOOM", little-endian *)
let version = 1

type layout =
  { base : int
  ; code_base : int
  ; data_base : int
  ; bss_base : int
  ; bss_length : int
  ; image_length : int
  }

let layout ~base ~code_words ~data_size ~bss_size =
  assert (data_size land 3 = 0 && bss_size land 3 = 0);
  let code_base = base + header_size in
  let data_base = code_base + (4 * code_words) in
  let bss_base = data_base + data_size in
  { base
  ; code_base
  ; data_base
  ; bss_base
  ; bss_length = bss_size
  ; image_length = bss_base - base (* header + code + data *)
  }
;;

let emit ~(layout : layout) ~(code : R.instr list) ~(data : bytes) ~entries =
  let init_off, tick_off, keyin_off = entries in
  let file = Bytes.make layout.image_length '\000' in
  (* code words after the header, data after the code *)
  List.iteri
    (fun i ins ->
       Bytes.set_int32_le file (header_size + (4 * i)) (Int32.of_int (R.encode ins)))
    code;
  Bytes.blit data 0 file (layout.data_base - layout.base) (Bytes.length data);
  (* checksum: additive u32 over the image words AFTER the header (code + data) *)
  let sum = ref 0 in
  for w = header_size / 4 to (layout.image_length / 4) - 1 do
    sum
    := (!sum + (Int32.to_int (Bytes.get_int32_le file (4 * w)) land 0xFFFF_FFFF))
       land 0xFFFF_FFFF
  done;
  (* the frozen v1 header (ABI §7) *)
  let word off v = Bytes.set_int32_le file off (Int32.of_int v) in
  word 0 magic;
  word 4 version;
  word 8 layout.image_length;
  word 12 layout.bss_base (* bss start, absolute *);
  word 16 layout.bss_length;
  word 20 init_off;
  word 24 tick_off;
  word 28 keyin_off;
  word 32 !sum;
  (* +36..+63 reserved, zero — Bytes.make gave us that *)
  file
;;
