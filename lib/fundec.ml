(* Per-function compilation (AGENT.md 1b): one CIL fundec -> its unresolved {!Linker.obj},
   for integer functions — straight-line code, if/while/for control flow
   (comparisons lower to SUB + a conditional branch; {!Linker.link} lays the branches out to
   PC-relative offsets), and word-sized memory through the s3.2 address calculus
   ([gen_addr]): globals/statics off DB (ABI §2/§6), array indexing, struct fields,
   deref chains, &global and array decay, and pointer arithmetic ([gen_ptr_arith] —
   ptr±int scaled by the pointee size, pow-2 ptr−ptr), plus sub-word access (s3.3:
   char/short via LDB/STB — halfwords composed from two bytes, no halfword op exists —
   with sign/zero extension on loads, casts, and param entry). The minimal vertical the
   differential jig exercises. Naive register allocation (ABI §2: a leaf may use R0-R11
   freely; args and return in R0..) — every variable keeps a fixed home register, so
   control-flow merge points need no reconciliation. Each function is a well-formed ABI
   callee (s4.1a): a prologue/epilogue saves and restores the callee-saved regs (R6-R11) it
   writes and returns through [B LNK] (ABI §3). Calls (s4.1b): a caller marshals args through
   the home area into R0-R3 and BLs the named callee; a *non-leaf* keeps its homes in
   callee-saved R6-R11 (they survive the call) and scratch in R0-R5, while a leaf keeps homes
   R0.. (a zero-cost frame when it touches only R0-R5). Stack args (s4.2): a callee with >4
   params sets FP = entry SP and loads args 5+ from FP+16.. into their homes; a caller with >4
   args stages them past the home area (SP+16..) and sizes its outgoing area to the widest call
   it makes (ABI §3). Variables that can't be a register (s4.3) — aggregate locals and
   address-taken scalars, local or parameter (CIL's [vaddrof]) — get an SP-relative frame slot
   (the locals region, between the outgoing area and the saves) and route through the same
   memory calculus a global does, based at the slot instead of DB; an address-taken param keeps
   its register home and the prologue spills it into the slot. A whole-struct assignment (s4.4) is a
   byte-wise memory copy — alignment-agnostic, since these structs are often sub-word-aligned; by-value
   struct args and returns never occur in DOOM (census) and stay refused. A comparison or [!] used
   as a value (s5.1) materializes 0/1 by branching over two immediate loads — RISC5 has no
   set-on-condition; signed compares read the overflow-aware N≠V, unsigned and pointer compares
   the carry (s5.2). Unsigned [>>] (s5.2b) is ROR + mask — RISC5 has no logical shift right, so a
   rotate then a mask of the low 32−n bits. switch / goto / break / continue (s5.3/s5.4) route
   through per-statement backend labels: a switch is a compare-and-branch dispatch chain, goto and
   continue a jump to a labeled statement. Anything outside the supported subset raises
   [Check.Unsupported] — refuse to miscompile rather than guess. Each message names the later
   slice that will handle it. *)

module C = GoblintCil (* the CIL front-end AST *)
module R = Emu.Risc5_isa (* the RISC5 instruction encoding we emit *)
module L = Linker (* the unresolved frag stream + instr-level linker (ABI §6) *)

let unsupported = Check.unsupported

let is_unsigned_int (t : C.typ) =
  match C.unrollType t with
  | C.TInt (ik, _) -> not (C.isSigned ik)
  | _ -> false
;;

(* ---- registers (ABI §2). Leaf ⇒ R0..R11 usable; R12-R15 = FP/DB/SP/LNK. ---- *)
type reg = int

let return_reg = 0
let max_reg = 11

let first_callee_saved =
  6 (* R6-R11 are callee-saved (ABI §2): save exactly what we write *)
;;

let fp_reg =
  12 (* FP = entry SP; anchors incoming stack args at FP+16.. (ABI §2/§3, s4.2) *)
;;

let db_reg = 13 (* DB, the data base: set by crt0 (runner, in the jig), never written *)
let sp_reg = 14 (* SP, full-descending, 4-aligned (ABI §2/§3) *)
let lnk_reg = 15 (* LNK: BL writes it; a callee returns via [B LNK] (To_reg) *)

(* Emission builds an unresolved {!Linker.frag} stream, not raw instrs — a branch's target
   only gets a word address once the whole *program* is laid out, so [compile] hands the frags
   to {!Linker.link} (labels/branches resolve there, alongside cross-function calls). *)
type ctx =
  { mutable rev_frags : L.frag list (* emitted frags, reversed *)
  ; homes : (int, reg) Hashtbl.t (* varinfo.vid -> home register (register locals) *)
  ; slots : (int, int) Hashtbl.t
    (* vid -> byte offset within the locals region, for a local that can't be a register:
       an aggregate or an address-taken scalar (s4.3). Addressed SP-relative, [slots_base]+off *)
  ; slots_base : int
    (* SP-offset where the locals region starts (above the outgoing area) *)
  ; globals : Globals.t (* globals: vid -> DB-relative offset (+ skip reasons) *)
  ; scratch_lo : reg (* low end of the scratch pool: above the homes (leaf), or the *)
  ; scratch_hi : reg (* caller-saved R0-R5 for a non-leaf (homes then sit in R6-R11) *)
  ; scratch_free : bool array (* is scratch register r free? (indexed by reg) *)
  ; mutable next_label : int (* fresh-label counter (label 0 is [func_end]) *)
  ; mutable loops : (int option * int) list
    (* enclosing loops/switches, innermost first: (continue target, break target). A loop has
       both; a switch has only a break (its [None] continue passes through to the loop above).
       [break] takes the nearest entry's break; [continue] the nearest with a continue. *)
  ; stmt_labels : (int, int) Hashtbl.t
    (* CIL stmt [sid] -> backend label, for statements that are jump targets (case/default in a
       switch, or a goto/label). Find-or-create, so a forward jump and its target agree. *)
  ; func_end : int (* shared epilogue label every [return] branches to *)
  ; mutable max_used : reg
    (* highest register written (homes + scratch); the callee-saved
                              save set is R[first_callee_saved..max_used] (ABI §2/§3) *)
  }

let emit ctx i = ctx.rev_frags <- L.Ins i :: ctx.rev_frags

let new_label ctx =
  let l = ctx.next_label in
  ctx.next_label <- l + 1;
  l
;;

let place ctx l = ctx.rev_frags <- L.Label l :: ctx.rev_frags

(* The backend label for a CIL jump-target statement (case/default/goto target), keyed by its
   stable [sid] so a forward jump and its later-placed target resolve to the same label. *)
let label_of_stmt ctx (s : C.stmt) =
  match Hashtbl.find_opt ctx.stmt_labels s.sid with
  | Some l -> l
  | None ->
    let l = new_label ctx in
    Hashtbl.replace ctx.stmt_labels s.sid l;
    l
;;

let bcc ctx cond neg l = ctx.rev_frags <- L.Bcc (cond, neg, l) :: ctx.rev_frags
let jmp ctx l = ctx.rev_frags <- L.Jmp l :: ctx.rev_frags
let call ctx name = ctx.rev_frags <- L.Call name :: ctx.rev_frags

let alloc_scratch ctx =
  let rec find r =
    if r > ctx.scratch_hi
    then
      unsupported
        "out of registers (naive alloc, scratch R%d-R%d full) — needs spilling"
        ctx.scratch_lo
        ctx.scratch_hi
    else if ctx.scratch_free.(r)
    then (
      ctx.scratch_free.(r) <- false;
      r)
    else find (r + 1)
  in
  let r = find ctx.scratch_lo in
  if r > ctx.max_used then ctx.max_used <- r;
  r
;;

(* Only R[scratch_lo..scratch_hi] are scratches — the homes and DB (R13) must never be
   freed; DB would even index past scratch_free. The bounds let every consumer of an
   address uniformly "free the base" (a no-op for DB and homes). *)
let is_scratch ctx r = r >= ctx.scratch_lo && r <= ctx.scratch_hi
let free_scratch ctx r = if is_scratch ctx r then ctx.scratch_free.(r) <- true

let home ctx (v : C.varinfo) =
  match Hashtbl.find_opt ctx.homes v.vid with
  | Some r -> r
  | None -> unsupported "unmapped local %s — internal error" v.vname
;;

(* A global's DB-relative offset. A [Globals]-skipped global re-raises its skip reason
   here, attributing the refusal to each function that touches it; a vid the layout
   never saw is a declaration with no definition anywhere — the linker/libc's problem. *)
let global_offset ctx (v : C.varinfo) =
  match Hashtbl.find_opt ctx.globals.Globals.offsets v.vid with
  | Some off -> off
  | None ->
    (match Hashtbl.find_opt ctx.globals.Globals.skipped v.vid with
     | Some why -> unsupported "%s" why
     | None -> unsupported "extern global without a definition — 3b linker / mini-libc")
;;

(* How a scalar memory access maps to RISC5 ops. There is no halfword op (LDW/LDB/STW/STB
   only, ABI §1), so a 16-bit access is *composed* from two byte ops — that is why Half is
   its own case, not a size. The bool is signedness, which drives the widening on a read:
   - Word: LDW / STW.
   - Byte s: LDB (zero-extends; sign-extend from bit 7 if [s]) / STB (truncates for free).
   - Half s: two LDB, little-endian (hi<<8 | lo), +sign-extend if [s] / two STB.
   Aggregates/float never reach a scalar load/store. *)
type access =
  | Word
  | Byte of bool
  | Half of bool

let classify_access (lv : C.lval) : access =
  let t = C.unrollType (C.typeOfLval lv) in
  match t with
  | (C.TInt _ | C.TEnum _ | C.TPtr _) when C.bitsSizeOf t = 32 -> Word
  | C.TInt (ik, _) when C.bitsSizeOf t = 8 -> Byte (C.isSigned ik)
  | C.TInt (ik, _) when C.bitsSizeOf t = 16 -> Half (C.isSigned ik)
  | C.TComp _ | C.TArray _ ->
    (* a whole aggregate never loads/stores as a scalar: a struct copy is intercepted in
       gen_instr (s4.4), by-value struct args/returns are refused at the call boundary. So
       reaching here is an aggregate used as a value in some other shape — unexpected. *)
    unsupported "aggregate used as a scalar value — unexpected CIL shape"
  | C.TFloat _ -> unsupported "float (ABI §4: banned in blob v1)"
  | _ -> unsupported "memory access of unsupported type"
;;

(* ---- instruction builders ---- *)
let alu ?(u = false) ?(v = false) op a b operand : R.instr =
  R.Alu { op; u; v; a; b; operand }
;;

let mov_reg d s = alu R.Mov d 0 (R.Reg s) (* R[d] <- R[s] *)

(* R[d] <- 32-bit constant n: one MOV if it fits a zero-extended 16-bit immediate, else
   MOV-high (u=1: R[d] = hi<<16) + IOR-low (zero-extended) — the canonical RISC5 build. *)
let load_const ctx d n =
  let n = n land 0xFFFF_FFFF in
  let lo = n land 0xFFFF
  and hi = (n lsr 16) land 0xFFFF in
  if hi = 0
  then emit ctx (alu R.Mov d 0 (R.Imm lo))
  else (
    emit ctx (alu ~u:true R.Mov d 0 (R.Imm hi));
    emit ctx (alu R.Ior d d (R.Imm lo)))
;;

(* [pow2_log n] is [Some k] iff n = 2^k — the strength-reduction test. *)
let pow2_log n =
  if n > 0 && n land (n - 1) = 0
  then (
    let k = ref 0 in
    while 1 lsl !k < n do
      incr k
    done;
    Some !k)
  else None
;;

(* Scale the index in [r] by the element size: pow-2 sizes strength-reduce to LSL,
   the rest MUL by immediate (built via load_const past 16 bits). Size 1 is free.
   Frees [r] when a new register is produced. *)
let scale_index ctx r size =
  if size = 1
  then r
  else (
    let d = alloc_scratch ctx in
    (match pow2_log size with
     | Some k -> emit ctx (alu R.Lsl d r (R.Imm k))
     | None ->
       if size <= 0xFFFF
       then emit ctx (alu R.Mul d r (R.Imm size))
       else (
         let c = alloc_scratch ctx in
         load_const ctx c size;
         emit ctx (alu R.Mul d r (R.Reg c));
         free_scratch ctx c));
    free_scratch ctx r;
    d)
;;

(* Element size behind a pointer-typed expression (for ptr±int scaling / ptr−ptr). *)
let pointee_size (t : C.typ) =
  match C.unrollType t with
  | C.TPtr (elem, _) -> C.bitsSizeOf elem / 8
  | _ -> unsupported "pointer arithmetic on a non-pointer — unexpected CIL shape"
;;

(* Fresh register <- [p] + [delta] (signed): one immediate ADD/SUB when [delta] fits the
   16-bit field (the folded p[±k] / q = q+1 idiom — scale collapsed into the constant),
   else build the constant and ADD. Frees [p] if it is a scratch. *)
let add_const ctx p delta =
  let rd = alloc_scratch ctx in
  if delta = 0
  then emit ctx (mov_reg rd p)
  else if delta > 0 && delta <= 0xFFFF
  then emit ctx (alu R.Add rd p (R.Imm delta))
  else if delta < 0 && -delta <= 0xFFFF
  then emit ctx (alu R.Sub rd p (R.Imm (-delta)))
  else (
    let c = alloc_scratch ctx in
    load_const ctx c delta;
    emit ctx (alu R.Add rd p (R.Reg c));
    free_scratch ctx c);
  free_scratch ctx p;
  rd
;;

let binop_instr op rd b c : R.instr =
  let rr o = alu o rd b (R.Reg c) in
  match op with
  | C.PlusA -> rr R.Add
  | C.MinusA -> rr R.Sub
  | C.Mult -> rr R.Mul
  | C.BAnd -> rr R.And
  | C.BOr -> rr R.Ior
  | C.BXor -> rr R.Xor
  | C.Shiftlt -> rr R.Lsl
  | C.Shiftrt -> rr R.Asr (* arithmetic; the unsigned case is guarded in gen_expr *)
  | C.Div | C.Mod ->
    unsupported "/ and %% lower to __div/__mod calls (ABI §5) — call slice"
  | C.Lt | C.Gt | C.Le | C.Ge | C.Eq | C.Ne ->
    (* a comparison never reaches the two-register builder: as a value gen_expr intercepts it
       (bool_from_flags, s5.1), as a condition gen_cond does *)
    unsupported "comparison — internal error (should be intercepted upstream)"
  | C.LAnd | C.LOr ->
    (* CIL lowers && / || in both value and condition contexts to control flow (a temp + if),
       so these two rarely survive as a BinOp; if one does, it's a later slice *)
    unsupported "short-circuit && / || as a value — later slice"
  | C.PlusPI | C.IndexPI | C.MinusPI | C.MinusPP ->
    (* pointer arithmetic needs the pointee size to scale — gen_expr intercepts it
       (gen_ptr_arith) before this two-register builder is ever reached *)
    unsupported "pointer arithmetic — internal error (should be intercepted upstream)"
;;

(* Narrow a value to a [bits]-wide sub-word (the one primitive behind cast narrowing,
   loaded-sub-word widening, and param entry narrowing). Signed → sign-extend by a
   LSL/ASR pair that lands the sign bit at bit 31; unsigned → mask (0xFF / 0xFFFF, both
   fit a 16-bit immediate). [narrow_to] produces a FRESH register and frees [r] — use it
   where [r] may be a home (a cast operand); [narrow_home] rewrites a home in place. *)
let narrow_to ctx r ~bits ~signed =
  let rd = alloc_scratch ctx in
  if signed
  then (
    let sh = 32 - bits in
    emit ctx (alu R.Lsl rd r (R.Imm sh));
    emit ctx (alu R.Asr rd rd (R.Imm sh)))
  else emit ctx (alu R.And rd r (R.Imm ((1 lsl bits) - 1)));
  free_scratch ctx r;
  rd
;;

let narrow_home ctx h ~bits ~signed =
  if signed
  then (
    let sh = 32 - bits in
    emit ctx (alu R.Lsl h h (R.Imm sh));
    emit ctx (alu R.Asr h h (R.Imm sh)))
  else emit ctx (alu R.And h h (R.Imm ((1 lsl bits) - 1)))
;;

(* Signedness of a comparison (s5.2): unsigned if an operand is an unsigned integer or a
   pointer. CIL lowers pointer </> to unsigned compares — and since our addresses are 24-bit the
   sign bit is never set, so the unsigned condition is exact (this is what unblocks pointer-walk
   [while (q < end)]). CIL's usual arithmetic conversions already unified the operand types, so
   one side decides. *)
let compare_unsigned (e : C.exp) : bool =
  match C.unrollType (C.typeOf e) with
  | C.TInt (ik, _) -> not (C.isSigned ik)
  | C.TPtr _ -> true
  | _ -> false
;;

(* A C relational op -> the RISC5 (cond, neg) that HOLDS iff [a op b] is true, given the flags
   from SUB a,b (a = first operand = minuend). ==/!= are sign-agnostic. Ordered ops split by
   signedness: signed uses the overflow-aware N≠V (Lt) / (N≠V)|Z (Le); unsigned uses the carry
   conditions — after SUB, RISC5 sets C on borrow, i.e. C iff a<b unsigned (verified in the
   emulator: flag_c = result > minuend), so below = Cs, below-or-same = Ls (C|Z). Shared by the
   value form (bool_from_flags, below) and the branch form (gen_cond). *)
let rel_cond ~(signed : bool) (op : C.binop) : (R.cond * bool) option =
  match op with
  | C.Eq -> Some (R.Eq, false)
  | C.Ne -> Some (R.Eq, true)
  | C.Lt -> Some ((if signed then R.Lt else R.Cs), false)
  | C.Ge -> Some ((if signed then R.Lt else R.Cs), true)
  | C.Le -> Some ((if signed then R.Le else R.Ls), false)
  | C.Gt -> Some ((if signed then R.Le else R.Ls), true)
  | _ -> None
;;

(* Materialize a comparison's truth as a 0/1 value (s5.1). RISC5 has no set-on-condition, so
   branch over two immediate loads; [tcond]/[tneg] (from [rel_cond]) is the condition that HOLDS
   iff the comparison is true, with the flags already set by the caller's SUB. [d] is allocated
   only after the operands are freed, so it never widens the operands' live range — register
   pressure is the top naive-alloc blocker. *)
let bool_from_flags ctx (tcond : R.cond) (tneg : bool) : reg =
  let d = alloc_scratch ctx in
  let l_true = new_label ctx in
  let l_end = new_label ctx in
  bcc ctx tcond tneg l_true;
  load_const ctx d 0;
  jmp ctx l_end;
  place ctx l_true;
  load_const ctx d 1;
  place ctx l_end;
  d
;;

(* ---- expressions: emit code computing [e], return the register holding its value ---- *)
let rec gen_expr ctx (e : C.exp) : reg =
  match e with
  | C.Const (C.CInt (ci, _, _)) ->
    let r = alloc_scratch ctx in
    load_const ctx r (C.Cilint.int_of_cilint ci);
    r
  | C.Const (C.CChr ch) ->
    let r = alloc_scratch ctx in
    load_const ctx r (Char.code ch);
    r
  | C.Lval (C.Var v, C.NoOffset) when (not v.vglob) && not (Hashtbl.mem ctx.slots v.vid)
    ->
    home
      ctx
      v (* a register local; a slotted one falls through to the memory load below *)
  | C.Lval lv -> gen_load ctx lv
  | C.AddrOf lv | C.StartOf lv ->
    (* &lv, and array decay — the same address, materialized as a value. A slotted local or
       param resolves to its frame slot (s4.3); a register var can't be address-taken (that
       would have slotted it), so a non-slotted local reaching gen_addr is an internal error. *)
    materialize_addr ctx lv
  | C.CastE (_, t, e') ->
    Check.check_unsupported_types t;
    if C.bitsSizeOf t >= 32
    then gen_expr ctx e' (* same-width or widening: the 32-bit value is unchanged *)
    else gen_narrow ctx t e'
  | C.UnOp (op, e', t) ->
    Check.check_unsupported_types t;
    gen_unop ctx op e'
  | C.BinOp (C.Shiftrt, e1, e2, t) when is_unsigned_int t ->
    (* logical >> (s5.2b): RISC5 has no LSR (ABI §1), only ASR (sign-fill) and ROR. So rotate
       right by n, then mask off the n low bits ROR wrapped into the top — leaving x's bits
       [n..31] in [0..31-n], zeros above = the logical shift. Constant count is the common case
       (FRACBITS, byte/colour extracts); a variable count needs a runtime mask (1<<(32-n))-1
       with an n=0 corner, deferred. The mask often exceeds a 16-bit immediate (n=1 → 0x7FFFFFFF)
       so it rides a register via load_const. *)
    (match C.getInteger (C.constFold true e2) with
     | Some c ->
       let n = C.Cilint.int_of_cilint c in
       if n = 0
       then gen_expr ctx e1 (* x >> 0 = x *)
       else if n >= 1 && n <= 31
       then (
         let r = gen_expr ctx e1 in
         let d = alloc_scratch ctx in
         emit ctx (alu R.Ror d r (R.Imm n));
         free_scratch ctx r;
         let m = alloc_scratch ctx in
         load_const ctx m ((1 lsl (32 - n)) - 1);
         emit ctx (alu R.And d d (R.Reg m));
         free_scratch ctx m;
         d)
       else unsupported "unsigned >> by %d — shift count outside 0..31 (undefined in C)" n
     | None ->
       unsupported "unsigned >> by a variable count (ROR + runtime mask) — later slice")
  | C.BinOp (((C.PlusPI | C.IndexPI | C.MinusPI | C.MinusPP) as op), e1, e2, t) ->
    Check.check_unsupported_types t;
    gen_ptr_arith ctx op e1 e2
  | C.BinOp (((C.Lt | C.Gt | C.Le | C.Ge | C.Eq | C.Ne) as op), e1, e2, t) ->
    (* a comparison as a *value* (s5.1; unsigned/pointer s5.2): x = a < b, return a == b, p < q
       (CIL: unsigned), … — SUB for the flags, then materialize 0/1. As an if/loop condition it
       goes through gen_cond instead. *)
    Check.check_unsupported_types t;
    let tcond, tneg =
      match rel_cond ~signed:(not (compare_unsigned e1)) op with
      | Some c -> c
      | None -> assert false (* the six relational ops all map *)
    in
    let r1 = gen_expr ctx e1 in
    let r2 = gen_expr ctx e2 in
    let s = alloc_scratch ctx in
    emit ctx (alu R.Sub s r1 (R.Reg r2)) (* flags = e1 - e2; s is dead *);
    free_scratch ctx s;
    free_scratch ctx r1;
    free_scratch ctx r2;
    bool_from_flags ctx tcond tneg
  | C.BinOp (op, e1, e2, t) ->
    Check.check_unsupported_types t;
    let r1 = gen_expr ctx e1 in
    let r2 = gen_expr ctx e2 in
    let rd = alloc_scratch ctx in
    emit ctx (binop_instr op rd r1 r2);
    free_scratch ctx r1;
    free_scratch ctx r2;
    rd
  | _ -> unsupported "expression form not supported yet — later slice"

and gen_unop ctx op e' =
  match op with
  | C.Neg ->
    (* 0 - x (RISC5 has no NEG) *)
    let r = gen_expr ctx e' in
    let z = alloc_scratch ctx in
    load_const ctx z 0;
    let rd = alloc_scratch ctx in
    emit ctx (alu R.Sub rd z (R.Reg r));
    free_scratch ctx z;
    free_scratch ctx r;
    rd
  | C.BNot ->
    (* x XOR 0xFFFFFFFF *)
    let r = gen_expr ctx e' in
    let m = alloc_scratch ctx in
    load_const ctx m 0xFFFF_FFFF;
    let rd = alloc_scratch ctx in
    emit ctx (alu R.Xor rd r (R.Reg m));
    free_scratch ctx m;
    free_scratch ctx r;
    rd
  | C.LNot ->
    (* !x is (x == 0) as a 0/1 value (s5.1): set flags from x (MOV sets N/Z), then materialize
       the Eq condition. Works for any scalar — int, char, pointer — since all test against 0. *)
    let r = gen_expr ctx e' in
    let s = alloc_scratch ctx in
    emit ctx (mov_reg s r) (* flags: Z = (x == 0); s is dead *);
    free_scratch ctx s;
    free_scratch ctx r;
    bool_from_flags ctx R.Eq false

(* Narrowing cast to a sub-word type, used as a *value*: e.g. (char)x, (short)x, or the
   coercion CIL inserts on a sub-word assignment / return. Unsigned masks to the low
   byte/halfword, signed sign-extends — [narrow_to] does both and keeps [e']'s home
   intact by returning a fresh register. (A *store* into a sub-word lval doesn't route
   here: STB truncates for free, and gen_store composes the halfword itself.) *)
and gen_narrow ctx (t : C.typ) (e' : C.exp) : reg =
  match C.unrollType t with
  | C.TInt (ik, _) when C.bitsSizeOf t = 8 || C.bitsSizeOf t = 16 ->
    narrow_to ctx (gen_expr ctx e') ~bits:(C.bitsSizeOf t) ~signed:(C.isSigned ik)
  | _ -> unsupported "narrowing cast to a non-integer sub-word type — later slice"

(* ---- pointer arithmetic (s3.2b). ptr±int scales the integer by the pointee size
   (LSL for pow-2, MUL otherwise) then ADD/SUB; a constant offset folds scale-and-add
   into one immediate (add_const). ptr−ptr subtracts to a byte gap, then divides by the
   pointee size — exact via ASR: C guarantees both pointers index one array, so the gap
   is an exact multiple of the size, and ASR of an exact multiple floors to the true
   quotient (negatives included). Non-pow-2 element sizes need __div (call slice). ---- *)
and gen_ptr_arith ctx (op : C.binop) (e1 : C.exp) (e2 : C.exp) : reg =
  let size = pointee_size (C.typeOf e1) in
  match op with
  | C.PlusPI | C.IndexPI | C.MinusPI ->
    let subtract = op = C.MinusPI in
    let p = gen_expr ctx e1 in
    (match C.getInteger (C.constFold true e2) with
     | Some c ->
       let mag = C.Cilint.int_of_cilint c * size in
       add_const ctx p (if subtract then -mag else mag)
     | None ->
       let scaled = scale_index ctx (gen_expr ctx e2) size in
       let rd = alloc_scratch ctx in
       emit ctx (alu (if subtract then R.Sub else R.Add) rd p (R.Reg scaled));
       free_scratch ctx scaled;
       free_scratch ctx p;
       rd)
  | C.MinusPP ->
    let p1 = gen_expr ctx e1 in
    let p2 = gen_expr ctx e2 in
    let d = alloc_scratch ctx in
    emit ctx (alu R.Sub d p1 (R.Reg p2));
    (* byte gap *)
    free_scratch ctx p1;
    free_scratch ctx p2;
    (match pow2_log size with
     | Some 0 -> d (* char*: byte gap already is the count *)
     | Some k ->
       emit ctx (alu R.Asr d d (R.Imm k));
       d
     | None ->
       unsupported "ptr−ptr with non-pow-2 element size — needs __div (call slice)")
  | _ -> unsupported "gen_ptr_arith: non-pointer op — internal error"

(* ---- the s3.2 address calculus: fold an lval into (base register, residual const).
   Constant hops — fields, constant indexes — accumulate in the residual, which rides
   free in the mem-op's 20-bit offset field, so p->f and a[3] stay one instruction;
   a dynamic index emits scale (LSL for pow-2 element sizes) + ADD. The caller does
   the final Load/Store/address-ADD and then frees the returned base (free_scratch
   no-ops on DB and homes). CIL guarantees every expression here is side-effect-free,
   so evaluation order is unconstrained. ---- *)
and gen_addr ctx ((host, off) : C.lval) : reg * int =
  let rec fold base residual (t : C.typ) (o : C.offset) =
    match o with
    | C.NoOffset -> base, residual
    | C.Field (fi, rest) ->
      if fi.fbitfield <> None then unsupported "bitfield access (ABI §4: banned)";
      let byte_off =
        fst (C.bitsOffset (C.TComp (fi.fcomp, [])) (C.Field (fi, C.NoOffset))) / 8
      in
      fold base (residual + byte_off) fi.ftype rest
    | C.Index (e, rest) ->
      let elem =
        match C.unrollType t with
        | C.TArray (elem, _, _) -> elem
        | _ -> unsupported "index into a non-array — unexpected CIL shape"
      in
      let esize = C.bitsSizeOf elem / 8 in
      (match C.getInteger (C.constFold true e) with
       | Some i -> fold base (residual + (C.Cilint.int_of_cilint i * esize)) elem rest
       | None ->
         let idx = gen_expr ctx e in
         let scaled = scale_index ctx idx esize in
         let nb = alloc_scratch ctx in
         emit ctx (alu R.Add nb base (R.Reg scaled));
         free_scratch ctx scaled;
         free_scratch ctx base;
         fold nb residual elem rest)
  in
  let base, residual, host_t =
    match host with
    | C.Var v when v.vglob -> db_reg, global_offset ctx v, v.vtype
    | C.Var v ->
      (* a slotted local (s4.3): its frame slot, SP-relative — the mirror of a global's
         DB-relative base, so the fold below layers fields/indexes on top identically *)
      (match Hashtbl.find_opt ctx.slots v.vid with
       | Some off -> sp_reg, ctx.slots_base + off, v.vtype
       | None ->
         unsupported "local %s used as memory but has no slot — internal error" v.vname)
    | C.Mem e ->
      let pointee =
        match C.unrollType (C.typeOf e) with
        | C.TPtr (t, _) -> t
        | _ -> unsupported "deref of a non-pointer — unexpected CIL shape"
      in
      gen_expr ctx e, 0, pointee
  in
  let base, residual = fold base residual host_t off in
  if residual >= -0x80000 && residual <= 0x7FFFF
  then base, residual
  else (
    (* a residual past the 20-bit mem-op range (giant constant index) folds into the
       base instead; everything sane keeps its one-instruction access *)
    let c = alloc_scratch ctx in
    load_const ctx c residual;
    let nb = alloc_scratch ctx in
    emit ctx (alu R.Add nb base (R.Reg c));
    free_scratch ctx c;
    free_scratch ctx base;
    nb, 0)

(* &lv / array decay: the address as a *value*. The 16-bit ALU-immediate limit shows
   the ISA asymmetry — *access* reaches ±512 KB through the 20-bit mem-op offset, but
   *address formation* past 64 K must build the constant first. *)
and materialize_addr ctx (lv : C.lval) : reg =
  let base, off = gen_addr ctx lv in
  if off = 0 && is_scratch ctx base
  then base
  else (
    free_scratch ctx base;
    let d = alloc_scratch ctx in
    if off = 0
    then emit ctx (mov_reg d base)
    else if off >= 0 && off <= 0xFFFF
    then emit ctx (alu R.Add d base (R.Imm off))
    else (
      let c = alloc_scratch ctx in
      load_const ctx c off;
      emit ctx (alu R.Add d base (R.Reg c));
      free_scratch ctx c);
    d)

and gen_load ctx (lv : C.lval) : reg =
  let acc = classify_access lv in
  let base, off = gen_addr ctx lv in
  match acc with
  | Word ->
    free_scratch ctx base;
    (* dest may reuse base: LDW Ra,Ra,off reads before writing *)
    let r = alloc_scratch ctx in
    emit ctx (R.Load { size = R.W; a = r; base; off });
    r
  | Byte signed ->
    free_scratch ctx base;
    let r = alloc_scratch ctx in
    emit ctx (R.Load { size = R.B; a = r; base; off });
    if signed then narrow_to ctx r ~bits:8 ~signed:true else r
  | Half signed ->
    (* no halfword op: compose (hi<<8) | lo from two LDBs (base held across both), then
       sign-extend if signed. off is the low byte, off+1 the high (little-endian). *)
    let hi = alloc_scratch ctx in
    emit ctx (R.Load { size = R.B; a = hi; base; off = off + 1 });
    emit ctx (alu R.Lsl hi hi (R.Imm 8));
    let lo = alloc_scratch ctx in
    emit ctx (R.Load { size = R.B; a = lo; base; off });
    free_scratch ctx base;
    let r = alloc_scratch ctx in
    emit ctx (alu R.Ior r hi (R.Reg lo));
    free_scratch ctx hi;
    free_scratch ctx lo;
    if signed then narrow_to ctx r ~bits:16 ~signed:true else r
;;

(* Store [r] into the scalar lval [lv]. STW/STB write directly; a halfword decomposes into
   two STB — the low byte, then the next byte via ASR 8 (STB takes only the low 8 bits, so
   the sign the ASR smears above bit 7 is harmless). *)
let gen_store ctx (lv : C.lval) (r : reg) : unit =
  let acc = classify_access lv in
  let base, off = gen_addr ctx lv in
  (match acc with
   | Word -> emit ctx (R.Store { size = R.W; a = r; base; off })
   | Byte _ -> emit ctx (R.Store { size = R.B; a = r; base; off })
   | Half _ ->
     emit ctx (R.Store { size = R.B; a = r; base; off });
     let hi = alloc_scratch ctx in
     emit ctx (alu R.Asr hi r (R.Imm 8));
     emit ctx (R.Store { size = R.B; a = hi; base; off = off + 1 });
     free_scratch ctx hi);
  free_scratch ctx base
;;

(* Whole-aggregate copy (s4.4): [dst = src] for struct-typed lvals — CIL keeps [a = b] a single
   struct-typed Set with an lval RHS. Byte-wise memory copy, unrolled over the compile-time
   size: alignment-agnostic on purpose, because these structs are often sub-word-aligned
   (mapthing_t is 5 shorts → align 2 and a 10-byte size; struct color is 4 chars → align 1) and
   LDW/STW would mask a non-4-aligned address. Cold in DOOM (census: 16 sites, none in the
   render path), so the naive 2-ops-per-byte is fine; word-copy when provably ≥4-aligned is a
   later optimization. Both ends go through materialize_addr, so [a=b], [*dp=*sp] and [arr[i]=s]
   all reduce to two base addresses + a byte shuttle — and every offset stays in [0, size). *)
let gen_struct_copy ctx (dst : C.lval) (src : C.lval) (size : int) : unit =
  let sptr = materialize_addr ctx src in
  let dptr = materialize_addr ctx dst in
  let tmp = alloc_scratch ctx in
  for k = 0 to size - 1 do
    emit ctx (R.Load { size = R.B; a = tmp; base = sptr; off = k });
    emit ctx (R.Store { size = R.B; a = tmp; base = dptr; off = k })
  done;
  free_scratch ctx tmp;
  free_scratch ctx sptr;
  free_scratch ctx dptr
;;

(* ---- statements ---- *)
let gen_instr ctx (i : C.instr) =
  match i with
  | C.Set (dst, e, _, _)
    when match C.unrollType (C.typeOfLval dst) with
         | C.TComp _ | C.TArray _ -> true
         | _ -> false ->
    (* whole-aggregate copy (s4.4): dst is struct-typed, so this is [dst = src] by value. CIL's
       RHS is the source lval (a=b, *dp=*sp, arr[i]=s); any other struct-typed RHS would be a
       by-value call return, which the call boundary already refuses (census: none in DOOM). *)
    let src =
      match e with
      | C.Lval src -> src
      | _ -> unsupported "aggregate assignment from a non-lval — unexpected CIL shape"
    in
    gen_struct_copy ctx dst src (C.bitsSizeOf (C.typeOfLval dst) / 8)
  | C.Set ((C.Var v, C.NoOffset), e, _, _)
    when (not v.vglob) && not (Hashtbl.mem ctx.slots v.vid) ->
    (* a register local: evaluate, then MOV into its home. A slotted local (aggregate or
       address-taken) falls through to the memory store below — and a whole-aggregate copy
       lands there too, where gen_store refuses it (s4.4). *)
    let r = gen_expr ctx e in
    let h = home ctx v in
    if r <> h then emit ctx (mov_reg h r);
    free_scratch ctx r
  | C.Set (lv, e, _, _) ->
    (* memory write: value first, then the address+store (CIL: both side-effect-free, so
       the order is free). gen_store picks STW/STB or composes the halfword. *)
    let r = gen_expr ctx e in
    gen_store ctx lv r;
    free_scratch ctx r
  | C.Call (lvopt, fexp, args, _, _) ->
    (* Direct call to a named function; args 1-4 in R0-R3, args 5+ on the stack, scalar/void
       return in R0 (ABI §3). Marshal through the outgoing area: evaluate each arg with the
       full scratch pool and STW it to SP+4i, then LDW R0-R3 from the first four slots.
       Evaluation and register placement decouple, so no half-loaded arg register is clobbered
       mid-setup; args 5+ stay where the stores left them (SP+16.., the callee's FP+16..), and
       the home area is left populated — what a ≤4-arg varargs callee expects. This function
       makes a call, so it is non-leaf: homes R6-R11, scratch R0-R5; [compile] sizes the
       outgoing area to the widest call it makes. *)
    let callee =
      match fexp with
      | C.Lval (C.Var f, C.NoOffset)
        when match C.unrollType f.vtype with
             | C.TFun _ -> true
             | _ -> false -> f
      | _ -> unsupported "indirect call (through a function pointer) — later slice"
    in
    (match C.unrollType callee.vtype with
     | C.TFun (rt, _, _, _) ->
       (match C.unrollType rt with
        | C.TComp _ | C.TArray _ ->
          unsupported
            "aggregate return (hidden pointer, ABI §3) — none in DOOM (census); deferred"
        | C.TFloat _ -> unsupported "float return (ABI §4: banned)"
        | _ -> ())
     | _ -> ());
    List.iter
      (fun a ->
         match C.unrollType (C.typeOf a) with
         | C.TComp _ | C.TArray _ ->
           unsupported
             "aggregate call arg (stack copy, ABI §3) — none in DOOM (census); deferred"
         | C.TFloat _ -> unsupported "float arg (ABI §4: banned)"
         | _ -> ())
      args;
    List.iteri
      (fun i a ->
         let r = gen_expr ctx a in
         emit ctx (R.Store { size = R.W; a = r; base = sp_reg; off = 4 * i });
         free_scratch ctx r)
      args;
    (* the first four slots become the register args; args 5+ stay on the stack at SP+16.. *)
    List.iteri
      (fun i _ ->
         if i < 4 then emit ctx (R.Load { size = R.W; a = i; base = sp_reg; off = 4 * i }))
      args;
    call ctx callee.vname;
    (match lvopt with
     | None -> () (* void call / result discarded *)
     | Some (C.Var v, C.NoOffset) when (not v.vglob) && not (Hashtbl.mem ctx.slots v.vid)
       ->
       let h = home ctx v in
       if h <> return_reg then emit ctx (mov_reg h return_reg)
     | Some (C.Var v, C.NoOffset) when not v.vglob ->
       gen_store
         ctx
         (C.Var v, C.NoOffset)
         return_reg (* result into a slotted local (s4.3) *)
     | Some _ -> unsupported "call result to a non-local lval — later slice")
  | C.VarDecl _ -> ()
  | C.Asm _ -> unsupported "inline asm — n/a"
;;

(* ---- conditions: branch to [false_label] when [cond] is false, else fall through ---- *)

let gen_cond ctx (cond : C.exp) ~(false_label : int) =
  (* fallback: treat [cond] as a value, false iff zero (the register write sets Z) *)
  let truthy () =
    let r = gen_expr ctx cond in
    let d = alloc_scratch ctx in
    emit ctx (mov_reg d r);
    free_scratch ctx d;
    free_scratch ctx r;
    bcc ctx R.Eq false false_label
  in
  match cond with
  | C.BinOp (op, e1, e2, _) ->
    (match rel_cond ~signed:(not (compare_unsigned e1)) op with
     | None -> truthy ()
     | Some (tcond, tneg) ->
       let r1 = gen_expr ctx e1 in
       let r2 = gen_expr ctx e2 in
       let s = alloc_scratch ctx in
       emit ctx (alu R.Sub s r1 (R.Reg r2));
       (* flags = e1 - e2; s is dead *)
       free_scratch ctx s;
       free_scratch ctx r1;
       free_scratch ctx r2;
       (* jump when the comparison is FALSE: {tcond, not tneg} *)
       bcc ctx tcond (not tneg) false_label)
  | _ -> truthy ()
;;

(* ---- statements ---- *)
let rec gen_stmt ctx (s : C.stmt) =
  (* a jump-target statement (a case/default in a switch, or a goto/label target) gets its
     backend label placed here — once, ahead of its body. Dispatch and gotos reach it through
     [label_of_stmt] on the same [sid], so forward references resolve (s5.3/s5.4). *)
  if s.labels <> [] then place ctx (label_of_stmt ctx s);
  match s.skind with
  | C.Instr instrs -> List.iter (gen_instr ctx) instrs
  | C.Block b -> List.iter (gen_stmt ctx) b.bstmts
  | C.Return (Some e, _, _) ->
    let r = gen_expr ctx e in
    if r <> return_reg then emit ctx (mov_reg return_reg r);
    free_scratch ctx r;
    jmp ctx ctx.func_end
  | C.Return (None, _, _) -> jmp ctx ctx.func_end
  | C.If (cond, then_b, else_b, _, _) ->
    if else_b.bstmts = []
    then (
      let l_end = new_label ctx in
      gen_cond ctx cond ~false_label:l_end;
      List.iter (gen_stmt ctx) then_b.bstmts;
      place ctx l_end)
    else (
      let l_else = new_label ctx in
      let l_end = new_label ctx in
      gen_cond ctx cond ~false_label:l_else;
      List.iter (gen_stmt ctx) then_b.bstmts;
      jmp ctx l_end;
      place ctx l_else;
      List.iter (gen_stmt ctx) else_b.bstmts;
      place ctx l_end)
  | C.Loop (body, _, _, _, _) ->
    (* CIL loops are infinite with the guard [if (c) {} else break] as the first body stmt;
       break/continue resolve against the loop stack. *)
    let l_top = new_label ctx in
    let l_break = new_label ctx in
    place ctx l_top;
    ctx.loops <- (Some l_top, l_break) :: ctx.loops;
    List.iter (gen_stmt ctx) body.bstmts;
    ctx.loops <- List.tl ctx.loops;
    jmp ctx l_top;
    place ctx l_break
  | C.Switch (e, body, cases, _, _) ->
    (* dispatch chain (a jump table is a later optimization): compare the switch value against
       each case constant and branch to that case's statement label; then fall through to the
       default (or past the switch). The case/default labels ride on the body statements and are
       placed when the body is emitted, so fall-through is the natural statement order. break
       exits to l_break; a switch offers no continue target — hence [None] on the stack. *)
    let r = gen_expr ctx e in
    let l_break = new_label ctx in
    let default = ref None in
    List.iter
      (fun (cs : C.stmt) ->
         let l = label_of_stmt ctx cs in
         List.iter
           (fun (lab : C.label) ->
              match lab with
              | C.Case (ve, _, _) ->
                let v =
                  match C.getInteger (C.constFold true ve) with
                  | Some c -> C.Cilint.int_of_cilint c
                  | None -> unsupported "non-constant case label — unexpected CIL shape"
                in
                let vr = alloc_scratch ctx in
                load_const ctx vr v;
                let s = alloc_scratch ctx in
                emit ctx (alu R.Sub s r (R.Reg vr)) (* flags = switch - case; s is dead *);
                free_scratch ctx s;
                free_scratch ctx vr;
                bcc ctx R.Eq false l (* switch == case -> that case *)
              | C.Default _ -> default := Some l
              | C.CaseRange _ -> unsupported "case ranges (GCC extension) — later slice"
              | C.Label _ -> ())
           cs.labels)
      cases;
    free_scratch ctx r;
    (match !default with
     | Some l -> jmp ctx l
     | None -> jmp ctx l_break);
    ctx.loops <- (None, l_break) :: ctx.loops;
    List.iter (gen_stmt ctx) body.bstmts;
    ctx.loops <- List.tl ctx.loops;
    place ctx l_break
  | C.Break _ ->
    (match ctx.loops with
     | (_, l_break) :: _ -> jmp ctx l_break
     | [] -> unsupported "break outside a loop/switch — unexpected CIL shape")
  | C.Continue _ ->
    (* continue targets the nearest enclosing *loop* (a switch's [None] passes through). For a
       CIL while/do loop that point is the loop top (re-test); a for-loop's continue was lowered
       by CIL to a goto before the increment, so it arrives as Goto below, not here. *)
    let rec loop_cont = function
      | (Some c, _) :: _ -> jmp ctx c
      | (None, _) :: rest -> loop_cont rest
      | [] -> unsupported "continue outside a loop — unexpected CIL shape"
    in
    loop_cont ctx.loops
  | C.Goto (target, _) ->
    (* CIL Goto references its target statement; that statement's label is placed when it is
       emitted (gen_stmt entry), so goto and target agree via [label_of_stmt] on the same sid —
       forward or backward. This also carries CIL's lowered for-loop continue (goto the increment). *)
    jmp ctx (label_of_stmt ctx !target)
  | C.ComputedGoto _ -> unsupported "computed goto (GCC &&label) — later slice"
;;

(* The call profile: [None] if the function is a leaf (makes no call), else [Some n] with n the
   widest argument count across its calls. A non-leaf clobbers LNK (BL writes it) and needs its
   live values to survive calls, so its homes move to callee-saved R6-R11 (ABI §2), it saves
   LNK, and it reserves a 4·max(4,n)-byte outgoing area — the 16-byte home area for R0-R3, plus
   a slot per stack arg 5+ (ABI §3). CIL statements nest only through these skinds. *)
let call_arity (fd : C.fundec) : int option =
  let widest = ref None in
  let note n =
    widest
    := Some
         (match !widest with
          | None -> n
          | Some k -> max k n)
  in
  let rec scan (s : C.stmt) =
    match s.skind with
    | C.Instr instrs ->
      List.iter
        (function
          | C.Call (_, _, args, _, _) -> note (List.length args)
          | _ -> ())
        instrs
    | C.Block b -> List.iter scan b.bstmts
    | C.If (_, a, b, _, _) ->
      List.iter scan a.bstmts;
      List.iter scan b.bstmts
    | C.Loop (b, _, _, _, _) -> List.iter scan b.bstmts
    | C.Switch (_, b, _, _, _) -> List.iter scan b.bstmts
    | _ -> ()
  in
  List.iter scan fd.sbody.bstmts;
  !widest
;;

(* ---- entry: a CIL fundec -> its unresolved {!Linker.obj} (args in R0.., return R0).
   [Linker.link] lays this out with any callees and resolves branches and calls. ---- *)
let compile ?(globals = Globals.no_globals) (fd : C.fundec) : L.obj =
  let return_type =
    match fd.svar.vtype with
    | C.TFun (rt, _, _, _) -> rt
    | t -> t
  in
  Check.check_unsupported_types return_type;
  List.iter
    (fun (v : C.varinfo) -> Check.check_unsupported_types v.vtype)
    (fd.sformals @ fd.slocals);
  (* CIL leaves every stmt's [sid] at -1 until a CFG pass runs; we key jump-target labels
     (case/default in a switch, goto targets) by sid, so number the statements ourselves. A
     local numbering suffices — we don't need CIL's succs/preds. The switch [cases] list and
     goto targets are the *same physical* statements as in the body, so numbering the body's
     tree covers them, and a dispatch/goto sees the same sid the placement does. *)
  let next_sid = ref 0 in
  let rec number (s : C.stmt) =
    s.sid <- !next_sid;
    incr next_sid;
    match s.skind with
    | C.Block b | C.Loop (b, _, _, _, _) | C.Switch (_, b, _, _, _) ->
      List.iter number b.bstmts
    | C.If (_, t, e, _, _) ->
      List.iter number t.bstmts;
      List.iter number e.bstmts
    | _ -> ()
  in
  List.iter number fd.sbody.bstmts;
  (* ABI §3: aggregates travel by hidden pointer / stack copy — call-slice machinery.
     A sub-word param arrives as a full word (caller / jig pass the raw int); every
     sub-word int is narrowed to its declared width at entry (below). *)
  (match C.unrollType return_type with
   | C.TComp _ | C.TArray _ ->
     unsupported
       "aggregate return (hidden pointer, ABI §3) — none in DOOM (census); deferred"
   | _ -> ());
  List.iter
    (fun (v : C.varinfo) ->
       match C.unrollType v.vtype with
       | C.TComp _ | C.TArray _ ->
         unsupported
           "aggregate param (stack copy, ABI §3) — none in DOOM (census); deferred"
       | _ -> ())
    fd.sformals;
  let call_info = call_arity fd in
  let leaf = call_info = None in
  (* >4 params (s4.2): args 5+ arrive on the stack, so the callee sets FP = entry SP and reads
     them at FP+16.. (below). The naive-alloc register ceiling still applies via [assign]. *)
  let needs_fp = List.length fd.sformals > 4 in
  let outgoing_area =
    match call_info with
    | None -> 0
    | Some n -> 4 * max 4 n
  in
  (* s4.3: a variable that can't live in a register — an aggregate, or a scalar whose address
     is taken (CIL's [vaddrof]) — gets a word-aligned slot in the frame's locals region, just
     above the outgoing area. Addressed SP-relative: the offset ([slots_base]+off) is known
     here, before body codegen fixes the save set — which an FP-relative offset couldn't be
     (it subtracts the frame size). Params as well as locals (step 2): an address-taken param
     keeps its register home (where it arrives) and the prologue spills it into its slot. *)
  let slots = Hashtbl.create 8 in
  let locals_size = ref 0 in
  let needs_slot (v : C.varinfo) =
    v.vaddrof
    ||
    match C.unrollType v.vtype with
    | C.TComp _ | C.TArray _ -> true
    | _ -> false
  in
  let alloc_slot (v : C.varinfo) =
    if needs_slot v
    then (
      Hashtbl.replace slots v.vid !locals_size;
      (* round each slot up to a word so the next stays 4-aligned (ABI §4) *)
      locals_size := !locals_size + (((C.bitsSizeOf v.vtype / 8) + 3) land lnot 3))
  in
  List.iter alloc_slot fd.sformals;
  List.iter alloc_slot fd.slocals;
  (* Non-leaf: homes go to callee-saved R6-R11 (survive calls), scratch to caller-saved
     R0-R5. Leaf: today's model — homes R0.., scratch above them. *)
  let home_base = if leaf then 0 else first_callee_saved in
  let homes = Hashtbl.create 16 in
  let next = ref home_base in
  let assign (v : C.varinfo) =
    if !next > max_reg
    then
      unsupported
        "too many params+locals for naive alloc (>%d regs) — needs spilling"
        (max_reg - home_base + 1);
    Hashtbl.replace homes v.vid !next;
    incr next
  in
  List.iter assign fd.sformals;
  (* slotted locals live in memory, not a register — skip them here *)
  List.iter
    (fun (v : C.varinfo) -> if not (Hashtbl.mem slots v.vid) then assign v)
    fd.slocals;
  let scratch_lo, scratch_hi =
    if leaf then !next, max_reg else 0, first_callee_saved - 1
  in
  let ctx =
    { rev_frags = []
    ; homes
    ; slots
    ; slots_base = outgoing_area
    ; globals
    ; scratch_lo
    ; scratch_hi
    ; scratch_free = Array.make (max_reg + 1) true
    ; next_label = 1 (* label 0 is func_end *)
    ; loops = []
    ; stmt_labels = Hashtbl.create 16
    ; func_end = 0
    ; max_used =
        !next - 1 (* the last home; scratch (and so the save set) grow from here *)
    }
  in
  (* entry narrowing (s3.3): a sub-word param arrives as a full word; narrow its home to
     the declared width so it holds the C-correct value from the first use (the jig's gcc
     oracle narrows at the call site — we get the raw int). Unsigned masks, signed
     sign-extends; the home register IS the canonical location, so rewrite it in place. A
     slotted param (s4.3 step 2) is skipped: its home is transient — the prologue spills it to
     the slot, and the slot's own sub-word load narrows on read. *)
  List.iter
    (fun (v : C.varinfo) ->
       match C.unrollType v.vtype with
       | C.TInt (ik, _) when C.bitsSizeOf v.vtype < 32 && not (Hashtbl.mem slots v.vid) ->
         narrow_home
           ctx
           (Hashtbl.find homes v.vid)
           ~bits:(C.bitsSizeOf v.vtype)
           ~signed:(C.isSigned ik)
       | _ -> ())
    fd.sformals;
  List.iter (gen_stmt ctx) fd.sbody.bstmts;
  (* The frame (ABI §3): SP-relative, low-to-high — outgoing area · locals region (s4.3) ·
     callee-saved R[6..max_used] · FP (needs_fp) · LNK (non-leaf). The saves are contiguous
     (homes then, for a leaf, scratch — both fill upward). The outgoing area (sized to the
     widest call, [call_info]) and the locals ([locals_size]) sit below the saves, so a pure
     leaf touching only R0-R5 with no slots gets frame = 0 (no SUB/ADD SP, just [B LNK]). *)
  let saved =
    List.init
      (max 0 (ctx.max_used - first_callee_saved + 1))
      (fun i -> first_callee_saved + i)
  in
  (* the saves start above the outgoing area and the locals region *)
  let saves_base = outgoing_area + !locals_size in
  let saves_end = saves_base + (4 * List.length saved) in
  (* slots above the saves: FP (needs_fp), then LNK (non-leaf), matching the ABI §3 idiom *)
  let fp_off = saves_end in
  let lnk_off = saves_end + if needs_fp then 4 else 0 in
  let frame = lnk_off + if leaf then 0 else 4 in
  (* epilogue at func_end: restore saves (+ LNK for a non-leaf), drop the frame, B LNK *)
  place ctx ctx.func_end;
  List.iteri
    (fun i r ->
       emit ctx (R.Load { size = R.W; a = r; base = sp_reg; off = saves_base + (4 * i) }))
    saved;
  if needs_fp
  then emit ctx (R.Load { size = R.W; a = fp_reg; base = sp_reg; off = fp_off });
  if not leaf
  then emit ctx (R.Load { size = R.W; a = lnk_reg; base = sp_reg; off = lnk_off });
  if frame > 0 then emit ctx (alu R.Add sp_reg sp_reg (R.Imm frame));
  emit
    ctx
    (R.Branch { cond = R.True; neg = false; link = false; target = R.To_reg lnk_reg });
  (* prologue: open the frame; save callee-saved (+ FP if needs_fp, + LNK if non-leaf); set
     FP = entry SP so incoming stack args land at FP+16..; then place params into their homes.
     The saves run first, preserving the caller's R6-R11/FP before we overwrite them. Params:
     args 1-4 move from R0-R3 (a non-leaf's homes; a leaf's already sit there), args 5+ (s4.2)
     load from the frame at FP+16.. — the caller staged them there at the BL (ABI §3). *)
  let prologue =
    if frame = 0
    then []
    else (
      let saves =
        List.mapi
          (fun i r ->
             L.Ins
               (R.Store { size = R.W; a = r; base = sp_reg; off = saves_base + (4 * i) }))
          saved
      in
      let fp_setup =
        if needs_fp
        then
          [ L.Ins (R.Store { size = R.W; a = fp_reg; base = sp_reg; off = fp_off })
          ; L.Ins (alu R.Add fp_reg sp_reg (R.Imm frame)) (* FP = SP + frame = entry SP *)
          ]
        else []
      in
      let lnk_save =
        if leaf
        then []
        else [ L.Ins (R.Store { size = R.W; a = lnk_reg; base = sp_reg; off = lnk_off }) ]
      in
      let param_setup =
        List.concat
          (List.mapi
             (fun i (v : C.varinfo) ->
                let h = Hashtbl.find homes v.vid in
                let place =
                  if i < 4
                  then if leaf then [] else [ L.Ins (mov_reg h i) ]
                  else
                    [ L.Ins (R.Load { size = R.W; a = h; base = fp_reg; off = 4 * i }) ]
                in
                (* an address-taken param (s4.3 step 2): once it lands in its home, spill the
                   home into its slot — the slot is its canonical location for body access. The
                   home carries it whether it arrived in a register (i<4) or on the stack. *)
                let spill =
                  match Hashtbl.find_opt slots v.vid with
                  | Some off ->
                    [ L.Ins
                        (R.Store
                           { size = R.W; a = h; base = sp_reg; off = outgoing_area + off })
                    ]
                  | None -> []
                in
                place @ spill)
             fd.sformals)
      in
      (L.Ins (alu R.Sub sp_reg sp_reg (R.Imm frame)) :: saves)
      @ fp_setup
      @ lnk_save
      @ param_setup)
  in
  { L.name = fd.svar.vname; frags = prologue @ List.rev ctx.rev_frags }
;;
