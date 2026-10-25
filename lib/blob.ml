(* The header layout is frozen (ABI §7): new fields go in the reserved tail
   (+36..+63, zero), anything else bumps the version. *)

module R = Emu.Risc5_isa
module AC = Abi_constants

let header_size = AC.header_size

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
  ; image_length = bss_base - base
  }
;;

let emit ~(layout : layout) ~(code : R.instr list) ~(data : bytes) ~entries =
  let init_off, tick_off, keyin_off = entries in
  let file = Bytes.make layout.image_length '\000' in
  List.iteri
    (fun i ins ->
       Bytes.set_int32_le file (header_size + (4 * i)) (Int32.of_int (R.encode ins)))
    code;
  Bytes.blit data 0 file (layout.data_base - layout.base) (Bytes.length data);
  let sum = ref 0 in
  for w = header_size / 4 to (layout.image_length / 4) - 1 do
    sum
    := (!sum + (Int32.to_int (Bytes.get_int32_le file (4 * w)) land 0xFFFF_FFFF))
       land 0xFFFF_FFFF
  done;
  let word off v = Bytes.set_int32_le file off (Int32.of_int v) in
  word AC.hdr_magic AC.magic;
  word AC.hdr_version AC.version;
  word AC.hdr_length layout.image_length;
  word AC.hdr_bss_base layout.bss_base;
  word AC.hdr_bss_length layout.bss_length;
  word AC.hdr_init init_off;
  word AC.hdr_tick tick_off;
  word AC.hdr_keyin keyin_off;
  word AC.hdr_checksum !sum;
  file
;;
