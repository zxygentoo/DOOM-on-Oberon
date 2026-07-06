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
  }

(** No globals at all (the default for bare {!Fundec.compile} calls). *)
val no_globals : t

(** Lay out every global definition ([GVar]) of a (merged) file. Never raises for an
    individual unplaceable global — those land in [skipped]. *)
val from_file : GoblintCil.file -> t
