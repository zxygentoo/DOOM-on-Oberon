(** Globals (static-storage) placement, DB-relative (ABI §2/§6) — the embryo of the
    3b linker's data/bss layout: every placed global gets a byte offset from DB (R13);
    initialized data is serialized little-endian into one zero-filled data+bss image
    the runner (jig) or stub (real machine) drops at the data base. *)

(** What a pointer-valued initializer points at: [Data off] is a DB-relative byte offset
    (a global, a string literal — patched to data base + off); [Code name] is a function,
    whose address exists only after {!Linker.link} lays the code out (patched via
    {!Linker.sym_addr}). *)
type reloc_target =
  | Data of int
  | Code of string

type t =
  { offsets : (int, int) Hashtbl.t (** [varinfo.vid] -> DB-relative byte offset *)
  ; skipped : (int, string) Hashtbl.t
    (** vid -> why it has no offset; {!Fundec} re-raises this on first use, so the
        refusal lands on the functions that touch the global, not the whole program *)
  ; strings : (string, int) Hashtbl.t
    (** interned string-literal content -> DB-relative byte offset of its bytes (with a NUL
        terminator) in [image]; identical literals share one copy. {!Fundec} materializes a
        [CStr] as [DB + offset], the same address form a global gets. *)
  ; relocs : (int * reloc_target) list
    (** pointer-valued initializer slots, (image byte offset, target): the image holds 0
        there, and the consumer patches in the absolute address once the bases are fixed
        — the jig at [Runner.data_base]/[Runner.code_base], the 3b linker at the blob's
        (ABI §6, pointer initializers as absolute words) *)
  ; image : bytes (** data+bss, little-endian, length padded to a word multiple *)
  ; data_size : int
    (** bytes of [image] that are data (initialized globals + interned strings, padded
        to a word); the zero tail past it is bss — placement orders initialized first,
        so the blob file carries only [0, data_size) and the stub zeroes the rest
        (ABI §7 bss start/length) *)
  }

(** Evaluate a compile-time integer constant: integer arithmetic through any cast chain
    (width-exact — narrowing casts wrap as the machine will), and constant *double*
    expressions under an integer cast, truncating toward zero — the automap zoom idiom
    [(int)(1.02*FRACUNIT)]. The s8 initializer evaluator, shared with {!Fundec}'s
    constant-cast fold; [None] = not a compile-time constant. *)
val int_core : GoblintCil.exp -> int option

(** Lay out every global definition ([GVar]) of a (merged) file. Never raises for an
    individual unplaceable global — those land in [skipped]. *)
val from_file : GoblintCil.file -> t

(** The DB-relative offset of the global named [name] in [file] — the seam hand-rolled
    code (the 1a drawers) uses to reach C-side data (dither's LUT + threshold map).
    [None] if no such global is defined or it was skipped. *)
val offset_of_name : t -> GoblintCil.file -> string -> int option
