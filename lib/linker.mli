(** The instr-level linker (ABI §6): resolve a set of compiled functions into one flat code
    image. This is {!Fundec}'s intra-function [resolve] lifted to a whole program — labels are
    function-local, calls cross functions, and both become concrete PC-relative offsets once
    the layout is known. The {!Emu.Risc5_isa.instr} output carries resolved offsets only;
    symbolic labels and call targets live here, the layer above the ISA (ABI §6). *)

module R = Emu.Risc5_isa

(** One function's unresolved instruction stream. [Label]/[Bcc]/[Jmp] carry function-local
    label ids; [Call] names a function resolved at link time. A [Label] is zero width; every
    other frag is one word. *)
type frag =
  | Ins of R.instr
  | Label of int
  | Bcc of R.cond * bool * int
  | Jmp of int
  | Call of string

type obj =
  { name : string
  ; frags : frag list
  }

type image =
  { code : R.instr list (* the flat resolved code, functions in [link] order *)
  ; symbols : (string * int) list (* function name -> word offset within [code] *)
  }

(** Word length of a function's resolved code (labels contribute 0). *)
val code_size : obj -> int

(** [link objs] lays the functions out in order and resolves every branch and call to a
    concrete offset. Raises {!Check.Unsupported} on a call to a name no object defines. *)
val link : obj list -> image
