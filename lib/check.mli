(** The pre-codegen checks (ABI §4 + the spikes/cil census), shared by {!Globals} and
    {!Fundec}: the single refusal channel — raised instead of miscompiling. *)

(** Raised for any construct the current slices do not handle; the message names the
    ABI rule violated or the slice responsible. doomcc histograms these messages. *)
exception Unsupported of string

(** [unsupported fmt ...] raises {!Unsupported} with a formatted message. *)
val unsupported : ('a, unit, string, 'b) format4 -> 'a

(** [check_unsupported_types t] rejects the ABI §4 banned types (float / 64-bit /
    bitfield), recursively through typedefs, struct fields and array elements. *)
val check_unsupported_types : GoblintCil.typ -> unit
