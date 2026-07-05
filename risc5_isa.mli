(* risc5_isa.mli — REFERENCE SKETCH, design companion to SEAM.md §6.

   The single definition of the RISC5 instruction encoding: one [instr] ADT,
   one [encode]/[decode], and the inlinable field accessors underneath both.

   This file is a spec artifact living in the DOOM repo; the implementation
   target is the HOST repo (oberon-risc-hardcaml) — stock OCaml, zero deps,
   upstream of: the compiler backend (1b), the instr-level linker (3b), the
   core tests, and — a later sub-project of its own — the emulator's own
   decode (single_step adopts the accessors at zero perf cost).

   Two layers, one truth:
     - accessors (Layer 1): word -> int/bool, allocation-free, [@inline] in
       the .ml. The emulator's hot loop and [decode] are both built on these;
       they ARE the bit-layout truth.
     - ADT + codec (Layer 2): the faithful, concrete, encodable instruction,
       for the compiler, disassembler, and tests. Never materialized in the
       emulator loop (that's what keeps the loop non-allocating).

   The SYMBOLIC layer — instructions with unresolved labels — lives ABOVE
   this module, in the DOOM-repo linker; [risc5_isa.instr] carries resolved
   offsets only. Text (a parser, a mnemonic disassembler) is deferred; the
   free debug floor is [@@deriving show] on [instr].

   Encoding (Wirth RISC5; confirmed field-for-field against the emulator's
   single_step, risc.ml):

     p = bit 31   q = bit 30   u = bit 29   v = bit 28
     ra = 27..24  rb = 23..20  op = 19..16  rc = 3..0   imm16 = 15..0

     register : p=0        q=0 register operand R[c] / q=1 immediate (F1)
                           u,v are op-specific modifiers (carry, high, flags,
                           unsigned, immediate sign-extend)
     memory   : p=1 q=0    off = 19..0 (signed); u = load/store, v = word/byte
     branch   : p=1 q=1    neg = 27, cond = 26..24, link = v;
                           u=0 register target R[c] (byte address),
                           u=1 PC-relative off = 23..0 (signed, in words)

   Invariants (property-tested; see 3b verify):
     decode (encode i) = i        for every constructible i        (always)
     encode (decode w) = w        for canonical w                  (don't-care
                                  bits zero — e.g. a register-target branch
                                  ignores bits 23..4, exactly as the hardware
                                  does; the shared accessors guarantee the
                                  match)
     accessors agree with the HardCaml core's decode               (the typed
                                  lockstep: [encode i] fed to the core does i) *)

type word = int
(* An UNSIGNED 32-bit value held in an OCaml [int]. Requires a 64-bit host:
   [int] is native-word-minus-one-tag-bit — 63-bit on 64-bit platforms, only
   31-bit on 32-bit ones (32-bit under js_of_ocaml) — and holding 0..2^32-1 as
   a non-negative int needs [Sys.int_size > 32] (not >=32: 0xFFFFFFFF must be
   positive, i.e. 33 signed bits; this also rejects jsoo's exactly-32). Same
   convention the emulator already uses (its [U32] module + [land 0xFFFF_FFFF]
   masking); [risc5_isa.ml] asserts [Sys.int_size > 32] at load so a non-64-bit
   build fails loud instead of silently truncating. [Int32.t] would be portable
   but boxed — it would allocate in every accessor and kill the zero-alloc
   hot path. *)

type reg = int (* 0..15 *)

(* The 4-bit op field (19..16). Nullary ⇒ immediate ⇒ zero-allocation. *)
type op =
  | Mov
  | Lsl
  | Asr
  | Ror
  | And
  | Ann
  | Ior
  | Xor
  | Add
  | Sub
  | Mul
  | Div
  | Fad
  | Fsb
  | Fml
  | Fdv

val int_of_op : op -> int
val op_of_int : int -> op (* total: all 16 values map *)

(* The 3-bit branch condition (26..24), paired with the negate bit (27). *)
type cond =
  | Mi (* N        — negative *)
  | Eq (* Z        — zero *)
  | Cs (* C        — carry set *)
  | Vs (* V        — overflow *)
  | Ls (* C|Z      — lower or same *)
  | Lt (* N<>V     — less than *)
  | Le (* (N<>V)|Z — less or equal *)
  | True (* always *)

val int_of_cond : cond -> int
val cond_of_int : int -> cond (* total: all 8 values map *)

(* ── Layer 1: accessors — the emulator's fast path. All [@inline] in the .ml,
   no allocation. These are the bit-layout truth; everything else builds on
   them. ── *)

type kind =
  | Register
  | Memory
  | Branch (* nullary ⇒ immediate; no allocation *)

val kind : word -> kind (* p, then q *)
val p : word -> bool (* bit 31 *)
val q : word -> bool (* bit 30 *)
val u : word -> bool (* bit 29 *)
val v : word -> bool (* bit 28 *)
val ra : word -> reg (* 27..24 : dest (register/memory); unused by branch *)
val rb : word -> reg (* 23..20 : source / memory base *)
val rc : word -> reg (*  3..0  : 2nd source / branch register target *)
val op_of_word : word -> op (* 19..16 *)
val imm16 : word -> int (* 15..0, zero-extended (raw field) *)
val imm_value : word -> int (* 15..0, sign-extended iff v — the F1 operand *)
val off20 : word -> int (* 19..0, sign-extended (memory offset) *)
val off24 : word -> int (* 23..0, sign-extended (branch word offset) *)
val cond_of_word : word -> cond (* 26..24 *)
val cond_neg : word -> bool (* bit 27 : negate the condition *)

(* ── Layer 2: the faithful, concrete ADT — legal states only. The
   operand/size/target constructors *imply* the q/u/v bits, so an illegal
   encoding can't be built; offsets are resolved ints (labels live above this
   module). ── *)

type operand =
  | Reg of reg (* q = 0 : register operand R[c] *)
  | Imm of int (* q = 1 : raw 16-bit field; sign-extension is a v/exec concern *)

type size =
  | W (* v = 0 : word *)
  | B (* v = 1 : byte *)

type target =
  | To_reg of reg (* u = 0 : R[c] holds a byte address *)
  | To_off of int (* u = 1 : 24-bit signed offset in words, PC-relative *)

type instr =
  | Alu of
      { op : op
      ; u : bool (* op-specific: carry (Add/Sub), unsigned (Mul/Div), high/flags (Mov) *)
      ; v : bool (* F1: sign-extend the immediate; Mov F0: flags vs H select *)
      ; a : reg
      ; b : reg
      ; operand : operand
      }
  | Load of { size : size; a : reg; base : reg; off : int } (* u = 0 *)
  | Store of { size : size; a : reg; base : reg; off : int } (* u = 1 *)
  | Branch of { cond : cond; neg : bool; link : bool; target : target }
  (* [@@deriving show] in the .ml — the free debug-print floor. A canonical
     mnemonic disassembler (BNE = {cond=Eq; neg=true}, etc.) is deferred. *)

val encode : instr -> word
val decode : word -> instr
