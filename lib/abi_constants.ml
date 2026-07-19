(* The ABI constants page, as code (ABI.md §7/§8/§11 — the values are FROZEN there;
   this module only gives them one definition per repo instead of one per consumer).
   Zero-dep on purpose: the emulator harnesses (bin/run_blob, bin/run_dsk) share it
   without pulling the compiler in. The Oberon stub (patch/oberon/DOOM.Mod) cannot,
   and re-states them — ABI.md remains the cross-language authority. *)

(* ---- §8 himem layout ---- *)

let blob_base = 0x100000
let blob_end_cap = 0x2C0000 (* code+data+bss must end below this: the 1.75 MB cap *)
let stack_top = 0x300000 (* the C stack grows down from here *)
let shared_base = 0x300000
let shared_size = 0x1000
let wad_base = 0xA00000
let wad_window_end = 0xE01000 (* 4 MiB + one page: the shareware WAD overruns 4 MiB *)

(* ---- §8 SHARED page field byte offsets ---- *)

let shared_status = 12 (* blob exit status: 0 running, 1 clean quit, <0 I_Error *)
let shared_heartbeat = 16 (* Tick bumps it once per call (gametic under -timedemo) *)
let shared_ring_head = 20 (* the §6 key ring: free-running u32 head / tail *)
let shared_ring_tail = 24
let shared_wad_len = 28 (* WAD byte length, written by the loader before Init *)
let shared_present_flags = 544 (* bit 0 = hw scanout advertised (ABI §11) *)
let shared_cmd_tail = 1024 (* the command tail: raw text + NUL, loader-written *)

(* ---- §7 blob header (64 bytes, v1 FROZEN — field byte offsets) ---- *)

let header_size = 64
let magic = 0x4D4F4F44 (* "DOOM", little-endian *)
let version = 1
let hdr_magic = 0
let hdr_version = 4
let hdr_length = 8 (* file length: header + code + data *)
let hdr_bss_base = 12 (* bss start, absolute — the loader zeroes the range *)
let hdr_bss_length = 16
let hdr_init = 20 (* entry offsets from blob_base; 0 = absent *)
let hdr_tick = 24
let hdr_keyin = 28
let hdr_checksum = 32 (* additive u32 over the image words after the header *)

(* ---- §11 halftone windows ---- *)

let ht_threshold_base = 0x30E000 (* the 64x64 threshold map upload window *)
let ht_pixel_base = 0x310000 (* the 8bpp pixel window scanout reads *)
