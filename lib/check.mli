(** The pre-codegen checks shared by {!Globals} and {!Fundec}, and the two ways
    compilation stops. *)

(** Raised for a construct the backend refuses rather than miscompile; the message
    names the reason, usually an ABI rule. doomcc turns the function into a trap and
    counts refusals by message. *)
exception Unsupported of string

(** [unsupported fmt ...] raises {!Unsupported} with a formatted message. *)
val unsupported : ('a, unit, string, 'b) format4 -> 'a

(** Raised when a backend invariant breaks — a bug in doomcc, never a property of the
    input. Deliberately not a refusal: doomcc fails the build rather than trap the
    function, so a backend bug can't ship as a quiet self-loop. *)
exception Internal of string

(** [internal fmt ...] raises {!Internal} with a formatted message. *)
val internal : ('a, unit, string, 'b) format4 -> 'a

(** [byte_bitfield fi] is true when the bitfield [fi] is degenerate — exactly 8 bits
    wide on a byte boundary, i.e. one addressable byte under the LSB-first
    little-endian allocation (struct color's b/g/r/a). These lower to LDB/STB; every
    other bitfield shape stays banned. *)
val byte_bitfield : GoblintCil.fieldinfo -> bool

(** [check_unsupported_types t] rejects the ABI §4 banned types (float / 64-bit /
    non-degenerate bitfield), recursively through typedefs, struct fields and array
    elements. *)
val check_unsupported_types : GoblintCil.typ -> unit
