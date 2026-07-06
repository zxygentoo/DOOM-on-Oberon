(** goblint-cil front end for the RISC5 target: parse C under the RISC5 machine model
    (ABI §4 — ILP32, little-endian, char unsigned) into the typed AST the backend
    consumes. Owns the machdep, installed on first parse. *)

(** [parse_file path] parses one preprocessed translation unit (.i). Raises [Failure] on
    parse errors. *)
val parse_file : string -> GoblintCil.file

(** [parse_string ~name src] parses a self-contained C snippet (no [#include] / no macros —
    headerless int code is already "preprocessed"); [name] labels the temporary unit.
    Raises [Failure] on parse errors. *)
val parse_string : name:string -> string -> GoblintCil.file

(** [merge units ~name] amalgamates parsed units into one (Mergecil.merge — the single-TU /
    PureDOOM rename step). Raises [Failure] on merge errors. *)
val merge : GoblintCil.file list -> name:string -> GoblintCil.file

(** [find_fundec file fname] returns the (single) function definition named [fname].
    Raises [Failure] if there is none. *)
val find_fundec : GoblintCil.file -> string -> GoblintCil.fundec

(** [fundecs file] returns every function definition in [file], in source order. *)
val fundecs : GoblintCil.file -> GoblintCil.fundec list
