(** The instr-level linker (ABI §6): resolve a set of compiled functions into one flat code
    image. This is {!Fundec}'s intra-function [resolve] lifted to a whole program — labels are
    function-local, calls cross functions, and both become concrete PC-relative offsets once
    the layout is known. The {!Emu.Risc5_isa.instr} output carries resolved offsets only;
    symbolic labels and call targets live here, the layer above the ISA (ABI §6). *)

module R = Emu.Risc5_isa

(** One function's unresolved instruction stream. [Label]/[Bcc]/[Jmp] carry function-local
    label ids; [Call] names a function resolved at link time (a PC-relative BL, so the code
    base cancels); [Addr] materializes a function's *absolute byte address* into a register
    — the code half of the pointer story (3b.1): a function has no address until layout is
    fixed, so it stays symbolic in the frag stream. A [Label] is zero width; [Addr] is two
    words (the load_const MOV-high/IOR pair, fixed-size even for small addresses so layout
    stays deterministic); every other frag is one word. *)
type frag =
  | Ins of R.instr
  | Label of int
  | Bcc of R.cond * bool * int
  | Jmp of int
  | Call of string
  | Addr of R.reg * string

type obj =
  { name : string
  ; frags : frag list
  }

type image =
  { code : R.instr list (* the flat resolved code, functions in [link] order *)
  ; symbols : (string * int) list
    (* function name -> word offset within [code], in layout order (the map dump) *)
  ; sym_tbl : (string, int) Hashtbl.t (* the same mapping, for O(1) lookups *)
  ; code_base : int (* the byte address the code is linked at (the [link] argument) *)
  }

(** The intrinsic registry (ABI §5, frozen at [{ FixedMul }]): a [Call] to one of these
    expands inline at resolve — MUL + read H + repack, the machine's 16.16 fixed-point
    party trick — clobbering exactly R0/R1/H/flags, a strict subset of a call's clobber
    set. Undefined-symbol scans must skip intrinsics: they resolve without a defining
    object. Taking an intrinsic's address is unsupported. *)
val is_intrinsic : string -> bool

(** Word length of a function's resolved code (labels contribute 0, [Addr] two,
    intrinsic [Call]s their expansion width). *)
val code_size : obj -> int

(** The canonical fixed 2-word absolute-constant build — MOV' the high halfword, IOR
    the low, ALWAYS two words even for a zero high half: everything sized before
    layout exists (the [Addr] expansion, crt0, the 1a eDSL's [load_const2]) depends
    on the width never varying with the value. The single definition of the shape. *)
val load_const_pair : R.reg -> int -> R.instr list

(** Every symbol a function's frags reference ([Call] and [Addr] targets) — the
    linker's own definition of "references", for undefined-symbol scans. *)
val referenced_syms : obj -> string list

(** A linked function's absolute byte address — what an [Addr] frag loads, and what a
    code-valued data reloc (a function-pointer initializer, {!Globals.reloc_target})
    patches in. Raises {!Check.Unsupported} on a name no object defines. *)
val sym_addr : image -> string -> int

(** [sym_addr]'s option-returning variant: [None] if no object defines [name]. *)
val find_sym_addr : image -> string -> int option

(** [link ~code_base objs] lays the functions out in order starting at byte address
    [code_base] and resolves every branch, call, and address to a concrete value. Raises
    {!Check.Unsupported} on a call to (or address of) a name no object defines. *)
val link : code_base:int -> obj list -> image
