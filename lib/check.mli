(** The pre-codegen checks (ABI §4 + the cil-spike.md census), shared by {!Globals} and
    {!Fundec}: the single refusal channel — raised instead of miscompiling. *)

(** Raised for any construct the current slices do not handle; the message names the
    ABI rule violated or the slice responsible. doomcc histograms these messages. *)
exception Unsupported of string

(** [unsupported fmt ...] raises {!Unsupported} with a formatted message. *)
val unsupported : ('a, unit, string, 'b) format4 -> 'a

(** [byte_bitfield fi] is true when the bitfield [fi] is degenerate — exactly 8 bits
    wide on a byte boundary, i.e. one addressable byte under the LSB-first
    little-endian allocation (struct color's b/g/r/a). These lower to LDB/STB; every
    other bitfield shape stays banned. *)
val byte_bitfield : GoblintCil.fieldinfo -> bool

(** [check_unsupported_types t] rejects the ABI §4 banned types (float / 64-bit /
    non-degenerate bitfield), recursively through typedefs, struct fields and array
    elements. *)
val check_unsupported_types : GoblintCil.typ -> unit
