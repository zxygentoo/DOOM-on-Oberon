(** The instruction-level linker (ABI §6): lay a set of functions out as one flat code
    image and resolve labels, calls and function addresses to concrete values. Labels
    are function-local; calls and addresses cross functions. The output carries
    resolved {!Emu.Risc5_isa.instr}s only — everything symbolic lives in {!frag}. *)

module R = Emu.Risc5_isa

(** One function's unresolved instruction stream. [Label]/[Bcc]/[Jmp] carry
    function-local label ids; [Call] names a function resolved at link time (a
    PC-relative BL, so the code base cancels); [Addr] loads a function's absolute byte
    address into a register — a function has no address until layout is fixed, so it
    stays symbolic. A [Label] is zero width; [Addr] is always two words (see
    {!load_const_pair}); every other frag is one word. *)
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
  { code : R.instr list (** the resolved code, functions in [link] order *)
  ; symbols : (string * int) list
    (** function name -> word offset within [code], in layout order (the map dump) *)
  ; sym_tbl : (string, int) Hashtbl.t (** the same mapping, for O(1) lookups *)
  ; code_base : int (** the byte address the code is linked at *)
  }

(** The intrinsic registry (ABI §5: [FixedMul] only). A [Call] to an intrinsic expands
    inline at resolve — MUL, read H, repack — clobbering exactly R0/R1/H/flags, a strict
    subset of a call's clobber set. Undefined-symbol scans must skip intrinsics: they
    resolve without a defining object. Taking an intrinsic's address is unsupported. *)
val is_intrinsic : string -> bool

(** Word length of a function's resolved code (labels contribute 0, [Addr] two,
    intrinsic [Call]s their expansion width). *)
val code_size : obj -> int

(** The 2-word absolute-constant build — MOV' the high halfword, IOR the low — always
    two words, even for a zero high half: everything sized before layout exists (the
    [Addr] expansion, {!Crt0}, [Asm.load_const2]) depends on the width never varying
    with the value. *)
val load_const_pair : R.reg -> int -> R.instr list

(** Every symbol a function's frags reference ([Call] and [Addr] targets), for
    undefined-symbol scans. *)
val referenced_syms : obj -> string list

(** A linked function's absolute byte address — what an [Addr] frag loads, and what a
    code-valued data reloc (a function-pointer initializer, {!Globals.reloc_target})
    patches in. Raises {!Check.Unsupported} on a name no object defines. *)
val sym_addr : image -> string -> int

(** [sym_addr]'s option-returning variant: [None] if no object defines [name]. *)
val find_sym_addr : image -> string -> int option

(** [link ~code_base objs] lays the functions out in order starting at byte address
    [code_base] and resolves every branch, call, and address to a concrete value. Raises
    {!Check.Unsupported} on a call to (or address of) a name no object defines, and
    [Invalid_argument] when two objects share a name. *)
val link : code_base:int -> obj list -> image
