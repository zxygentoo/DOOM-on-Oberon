(** Globals (static-storage) placement, DB-relative (ABI §2/§6) — the embryo of the
    3b linker's data/bss layout: every placed global gets a byte offset from DB (R13);
    initialized data is serialized little-endian into one zero-filled data+bss image
    the runner (jig) or stub (real machine) drops at the data base. *)

type t =
  { offsets : (int, int) Hashtbl.t (** [varinfo.vid] -> DB-relative byte offset *)
  ; skipped : (int, string) Hashtbl.t
    (** vid -> why it has no offset; {!Fundec} re-raises this on first use, so the
        refusal lands on the functions that touch the global, not the whole program *)
  ; image : bytes (** data+bss, little-endian, length padded to a word multiple *)
  }

(** No globals at all (the default for bare {!Fundec.compile} calls). *)
val no_globals : t

(** Lay out every global definition ([GVar]) of a (merged) file. Never raises for an
    individual unplaceable global — those land in [skipped]. *)
val from_file : GoblintCil.file -> t
