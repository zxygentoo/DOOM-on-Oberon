(** The ABI constants page, as code — ABI.md §7/§8/§11's frozen values with one
    definition per repo: the himem layout, the SHARED page field offsets, the blob
    header field offsets, and the halftone windows. Zero-dep so the emulator
    harnesses share it without pulling the compiler in; the Oberon stub re-states
    them, with ABI.md as the cross-language authority. *)

(** {2 §8 himem layout} *)

val blob_base : int
val blob_end_cap : int
val stack_top : int
val shared_base : int
val shared_size : int
val wad_base : int
val wad_window_end : int

(** {2 §8 SHARED page field byte offsets} *)

val shared_status : int
val shared_heartbeat : int
val shared_ring_head : int
val shared_ring_tail : int
val shared_wad_len : int
val shared_present_flags : int
val shared_cmd_tail : int

(** {2 §7 blob header (64 bytes, v1 frozen)} *)

val header_size : int
val magic : int
val version : int
val hdr_magic : int
val hdr_version : int
val hdr_length : int
val hdr_bss_base : int
val hdr_bss_length : int
val hdr_init : int
val hdr_tick : int
val hdr_keyin : int
val hdr_checksum : int

(** {2 §11 halftone windows} *)

val ht_threshold_base : int
val ht_pixel_base : int
