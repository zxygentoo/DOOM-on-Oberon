(** The ABI constants (ABI.md §7, §8, §11) as code, one definition per repo. No
    dependencies, so the emulator harnesses use it without the compiler. The Oberon
    stub restates these values; ABI.md is the authority. *)

(** {2 §8 himem layout} *)

val blob_base : int

(** code + data + bss must end below this: the 1.75 MB cap *)
val blob_end_cap : int

(** the C stack grows down from here *)
val stack_top : int

val shared_base : int
val shared_size : int
val wad_base : int

(** 4 MiB + one page: the shareware WAD overruns 4 MiB *)
val wad_window_end : int

(** {2 §8 SHARED page field byte offsets} *)

(** blob exit status: 0 running, 1 clean quit, < 0 I_Error *)
val shared_status : int

(** bumped once per Tick (the gametic under -timedemo) *)
val shared_heartbeat : int

(** the key ring's free-running u32 head and tail *)
val shared_ring_head : int

val shared_ring_tail : int

(** WAD byte length, written by the loader before Init *)
val shared_wad_len : int

(** bit 0: hardware scanout advertised (§11) *)
val shared_present_flags : int

(** the command tail: raw text + NUL, written by the loader *)
val shared_cmd_tail : int

(** {2 §7 blob header (64 bytes)} *)

val header_size : int

(** "DOOM", little-endian *)
val magic : int

val version : int
val hdr_magic : int
val hdr_version : int

(** file length: header + code + data *)
val hdr_length : int

(** absolute bss start; the loader zeroes the range *)
val hdr_bss_base : int

val hdr_bss_length : int

(** entry offsets from [blob_base]; 0 = absent *)
val hdr_init : int

val hdr_tick : int
val hdr_keyin : int

(** additive u32 over the image words after the header *)
val hdr_checksum : int

(** {2 §11 Halftone windows} *)

(** the 64×64 threshold-map upload window *)
val ht_threshold_base : int

(** the 8bpp pixel window the scanout reads *)
val ht_pixel_base : int
