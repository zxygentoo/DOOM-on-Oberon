(* Per-function compilation (AGENT.md 1b): one CIL fundec -> its Risc5_isa.instr list,
   for integer *leaf* functions — straight-line code, if/while/for control flow
   (comparisons lower to SUB + a conditional branch; [resolve] lays the branches out to
   PC-relative offsets), and word-sized memory through the s3.2 address calculus
   ([gen_addr]): globals/statics off DB (ABI §2/§6), array indexing, struct fields,
   deref chains, &global and array decay, and pointer arithmetic ([gen_ptr_arith] —
   ptr±int scaled by the pointee size, pow-2 ptr−ptr), plus unsigned-char access
   (LDB/STB + entry/cast narrowing, s3.3a). The minimal vertical the differential jig
   exercises. Naive register allocation (ABI §2: a leaf may use R0-R11
   freely; args and return in R0..) — every variable keeps a fixed home register, so
   control-flow merge points need no reconciliation. Anything outside the supported subset raises
   [Check.Unsupported] — refuse to miscompile rather than guess. Each message names the
   later slice that will handle it. *)

module C = GoblintCil (* the CIL front-end AST *)
module R = Emu.Risc5_isa (* the RISC5 instruction encoding we emit *)

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
let db_reg = 13 (* DB, the data base: set by crt0 (runner, in the jig), never written *)

(* Emission carries labels/branches, not raw instrs — a branch's target only gets a word
   address once the whole body is laid out. [resolve] (below) turns frags into the final
   [instr list]: the intra-function baby form of 3b's instr-level linker. *)
type frag =
  | Ins of R.instr (* one real instruction (width 1) *)
  | Label of int (* a branch target — zero width *)
  | Bcc of R.cond * bool * int (* conditional branch (cond, neg) to a label *)
  | Jmp of int (* unconditional branch to a label *)

type ctx =
  { mutable rev_frags : frag list (* emitted frags, reversed *)
  ; homes : (int, reg) Hashtbl.t (* varinfo.vid -> home register *)
  ; globals : Globals.t (* globals: vid -> DB-relative offset (+ skip reasons) *)
  ; base_scratch : reg (* first register above the homes *)
  ; scratch_free : bool array (* is scratch register r free? (indexed by reg) *)
  ; mutable next_label : int (* fresh-label counter (label 0 is [func_end]) *)
  ; mutable loops : (int * int) list (* enclosing loops: (continue=top, break) targets *)
  ; func_end : int (* shared epilogue label every [return] branches to *)
  }

let emit ctx i = ctx.rev_frags <- Ins i :: ctx.rev_frags

let new_label ctx =
  let l = ctx.next_label in
  ctx.next_label <- l + 1;
  l
;;

let place ctx l = ctx.rev_frags <- Label l :: ctx.rev_frags
let bcc ctx cond neg l = ctx.rev_frags <- Bcc (cond, neg, l) :: ctx.rev_frags
let jmp ctx l = ctx.rev_frags <- Jmp l :: ctx.rev_frags

let alloc_scratch ctx =
  let rec find r =
    if r > max_reg
    then
      unsupported
        "out of registers (naive alloc over %d homes) — needs spilling"
        ctx.base_scratch
    else if ctx.scratch_free.(r)
    then (
      ctx.scratch_free.(r) <- false;
      r)
    else find (r + 1)
  in
  find ctx.base_scratch
;;

(* Only R[base_scratch..max_reg] are scratches — the homes below and DB (R13) must
   never be freed; DB would even index past scratch_free. The upper bound lets every
   consumer of an address uniformly "free the base" (a no-op for DB and homes). *)
let is_scratch ctx r = r >= ctx.base_scratch && r <= max_reg
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

(* The RISC5 memory size for a scalar access — and the widening rule that rides with it:
   - word (int/enum/ptr): LDW/STW.
   - unsigned char: LDB zero-extends to a correct int (ABI §1) — no fixup; STB truncates.
   s3.3b adds signed char (LDB + sign-extend) and short (composed from two bytes, no
   halfword op exists). Aggregates/float never reach a scalar load/store. *)
let access_size (lv : C.lval) : R.size =
  let t = C.unrollType (C.typeOfLval lv) in
  match t with
  | (C.TInt _ | C.TEnum _ | C.TPtr _) when C.bitsSizeOf t = 32 -> R.W
  | C.TInt (ik, _) when C.bitsSizeOf t = 8 && not (C.isSigned ik) -> R.B
  | C.TInt (_, _) when C.bitsSizeOf t = 8 ->
    unsupported "signed char access (LDB + sign-extend) — memory slice s3.3b"
  | C.TInt _ -> unsupported "short access (composed from bytes) — memory slice s3.3b"
  | C.TComp _ | C.TArray _ ->
    unsupported "aggregate load/store (struct copy) — later slice"
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
  | C.Lt | C.Gt | C.Le | C.Ge | C.Eq | C.Ne | C.LAnd | C.LOr ->
    (* a comparison used as a *value* (x = a < b) needs 0/1 materialization — later slice.
       As an if/loop condition it never reaches here: gen_cond intercepts it. *)
    unsupported "comparison as a value (0/1 materialization) — later slice"
  | C.PlusPI | C.IndexPI | C.MinusPI | C.MinusPP ->
    (* pointer arithmetic needs the pointee size to scale — gen_expr intercepts it
       (gen_ptr_arith) before this two-register builder is ever reached *)
    unsupported "pointer arithmetic — internal error (should be intercepted upstream)"
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
  | C.Lval (C.Var v, C.NoOffset) when not v.vglob -> home ctx v
  | C.Lval lv ->
    (* memory read — global/element/deref scalar: one Load (LDW word, LDB char) off the
       folded (base, residual) address *)
    let size = access_size lv in
    let base, off = gen_addr ctx lv in
    free_scratch ctx base;
    (* dest may reuse it: LDW Ra,Ra,off reads before writing *)
    let r = alloc_scratch ctx in
    emit ctx (R.Load { size; a = r; base; off });
    r
  | C.AddrOf (C.Var v, _) when not v.vglob ->
    unsupported "&local (needs a stack slot in the ABI §3 frame) — call slice"
  | C.AddrOf lv | C.StartOf lv ->
    (* &lv, and array decay — the same address, materialized as a value *)
    materialize_addr ctx lv
  | C.CastE (_, t, e') ->
    Check.check_unsupported_types t;
    if C.bitsSizeOf t >= 32
    then gen_expr ctx e' (* same-width or widening: the 32-bit value is unchanged *)
    else gen_narrow ctx t e'
  | C.UnOp (op, e', t) ->
    Check.check_unsupported_types t;
    gen_unop ctx op e'
  | C.BinOp (C.Shiftrt, _, _, t) when is_unsigned_int t ->
    unsupported "unsigned >> (compiles to ROR + mask) — later slice"
  | C.BinOp (((C.PlusPI | C.IndexPI | C.MinusPI | C.MinusPP) as op), e1, e2, t) ->
    Check.check_unsupported_types t;
    gen_ptr_arith ctx op e1 e2
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
  | C.LNot -> unsupported "logical ! (0/1 materialization) — later slice"

(* Narrowing cast to a sub-word type, used as a *value*: e.g. (char)x, or the coercion
   CIL inserts on a char-typed assignment / return. (unsigned char) x = x AND 0xFF (the
   low byte, zero-extended). signed char / short need sign-extension — s3.3b. A store
   into a char lval needs no cast here: STB truncates for free. *)
and gen_narrow ctx (t : C.typ) (e' : C.exp) : reg =
  match C.unrollType t with
  | C.TInt (ik, _) when C.bitsSizeOf t = 8 && not (C.isSigned ik) ->
    let r = gen_expr ctx e' in
    let rd = alloc_scratch ctx in
    emit ctx (alu R.And rd r (R.Imm 0xFF));
    free_scratch ctx r;
    rd
  | _ -> unsupported "narrowing cast to signed char / short — memory slice s3.3b"

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
      unsupported
        "local %s used as memory (array/struct local needs a stack slot) — call slice"
        v.vname
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
;;

(* ---- statements ---- *)
let gen_instr ctx (i : C.instr) =
  match i with
  | C.Set ((C.Var v, C.NoOffset), e, _, _) when not v.vglob ->
    (match C.unrollType v.vtype with
     | C.TComp _ | C.TArray _ ->
       (* an aggregate "fits" in a register home only by accident — never emit the
          bogus MOV, even though no supported construct could observe it yet *)
       unsupported "aggregate assignment (struct copy) — later slice"
     | _ -> ());
    let r = gen_expr ctx e in
    let h = home ctx v in
    if r <> h then emit ctx (mov_reg h r);
    free_scratch ctx r
  | C.Set (lv, e, _, _) ->
    (* memory write: value, then address (CIL: both side-effect-free, order is free).
       STB truncates to the low byte, so a char store needs no extra masking. *)
    let size = access_size lv in
    let r = gen_expr ctx e in
    let base, off = gen_addr ctx lv in
    emit ctx (R.Store { size; a = r; base; off });
    free_scratch ctx base;
    free_scratch ctx r
  | C.Call _ -> unsupported "function call — call slice"
  | C.VarDecl _ -> ()
  | C.Asm _ -> unsupported "inline asm — n/a"
;;

(* ---- conditions: branch to [false_label] when [cond] is false, else fall through ---- *)

(* A C relational op -> the RISC5 (cond, neg) that HOLDS iff [a op b] is true, given the flags
   from SUB a,b. Signed: Lt = N≠V, Le = (N≠V)|Z, Eq = Z. Ordered ops are signed-only for now
   (unsigned < / <= need the carry conditions — a later slice); ==/!= are sign-agnostic. *)
let rel_cond (op : C.binop) : (R.cond * bool) option =
  match op with
  | C.Eq -> Some (R.Eq, false)
  | C.Ne -> Some (R.Eq, true)
  | C.Lt -> Some (R.Lt, false)
  | C.Ge -> Some (R.Lt, true)
  | C.Le -> Some (R.Le, false)
  | C.Gt -> Some (R.Le, true)
  | _ -> None
;;

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
    (match rel_cond op with
     | None -> truthy ()
     | Some (tcond, tneg) ->
       (match op with
        | (C.Lt | C.Gt | C.Le | C.Ge) when is_unsigned_int (C.typeOf e1) ->
          unsupported "unsigned ordered comparison — needs carry conditions, later slice"
        | _ -> ());
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
    ctx.loops <- (l_top, l_break) :: ctx.loops;
    List.iter (gen_stmt ctx) body.bstmts;
    ctx.loops <- List.tl ctx.loops;
    jmp ctx l_top;
    place ctx l_break
  | C.Break _ ->
    (match ctx.loops with
     | (_, l_break) :: _ -> jmp ctx l_break
     | [] -> unsupported "break outside a loop — unexpected CIL shape")
  | C.Continue _ ->
    unsupported "continue — later slice (needs the for-loop increment continuation point)"
  | C.Goto _ | C.ComputedGoto _ -> unsupported "goto — later slice"
  | C.Switch _ -> unsupported "switch — later slice"
;;

(* ---- resolve: frags -> instr list. Pass 1 assigns each frag a word address (labels are
   zero width); pass 2 rewrites branches to PC-relative offsets. A RISC5 PC-relative branch at
   word A lands at A+1+off (risc.ml), so off = target - A - 1. Intra-function only, no
   relocation — 3b's linker generalizes this across the whole blob. ---- *)
let resolve (frags : frag list) : R.instr list =
  let addr = Hashtbl.create 16 in
  ignore
    (List.fold_left
       (fun a f ->
          match f with
          | Label l ->
            Hashtbl.replace addr l a;
            a
          | Ins _ | Bcc _ | Jmp _ -> a + 1)
       0
       frags);
  let branch cond neg l a =
    R.Branch { cond; neg; link = false; target = R.To_off (Hashtbl.find addr l - a - 1) }
  in
  let out = ref []
  and a = ref 0 in
  List.iter
    (fun f ->
       match f with
       | Label _ -> ()
       | Ins i ->
         out := i :: !out;
         incr a
       | Bcc (cond, neg, l) ->
         out := branch cond neg l !a :: !out;
         incr a
       | Jmp l ->
         out := branch R.True false l !a :: !out;
         incr a)
    frags;
  List.rev !out
;;

(* ---- entry: an integer leaf -> its instr list (args in R0.., return R0) ---- *)
let compile ?(globals = Globals.no_globals) (fd : C.fundec) : R.instr list =
  let return_type =
    match fd.svar.vtype with
    | C.TFun (rt, _, _, _) -> rt
    | t -> t
  in
  Check.check_unsupported_types return_type;
  List.iter
    (fun (v : C.varinfo) -> Check.check_unsupported_types v.vtype)
    (fd.sformals @ fd.slocals);
  (* ABI §3: aggregates travel by hidden pointer / stack copy — call-slice machinery.
     A sub-word param arrives as a full word (caller / jig pass the raw int); unsigned
     char is narrowed at entry (below), short / signed char are s3.3b. *)
  (match C.unrollType return_type with
   | C.TComp _ | C.TArray _ ->
     unsupported "aggregate return (hidden pointer, ABI §3) — call slice"
   | _ -> ());
  List.iter
    (fun (v : C.varinfo) ->
       let t = C.unrollType v.vtype in
       match t with
       | C.TComp _ | C.TArray _ ->
         unsupported "aggregate param (stack copy, ABI §3) — call slice"
       | C.TInt (ik, _) when C.bitsSizeOf t = 8 && not (C.isSigned ik) -> ()
       | C.TInt _ when C.bitsSizeOf t < 32 ->
         unsupported "short / signed-char param (entry narrowing) — memory slice s3.3b"
       | _ -> ())
    fd.sformals;
  if List.length fd.sformals > 4 then unsupported ">4 params (stack args — call slice)";
  let homes = Hashtbl.create 16 in
  let next = ref 0 in
  let assign (v : C.varinfo) =
    if !next > max_reg
    then unsupported "too many params+locals for naive alloc (>%d regs)" (max_reg + 1);
    Hashtbl.replace homes v.vid !next;
    incr next
  in
  List.iter assign fd.sformals;
  List.iter assign fd.slocals;
  let ctx =
    { rev_frags = []
    ; homes
    ; globals
    ; base_scratch = !next
    ; scratch_free = Array.make (max_reg + 1) true
    ; next_label = 1 (* label 0 is func_end *)
    ; loops = []
    ; func_end = 0
    }
  in
  (* entry narrowing (s3.3a): an unsigned-char param arrives as a full word; mask its
     home to the low byte so it holds the C-correct value from the first use (the jig's
     gcc oracle narrows at the call site — we get the raw int). *)
  List.iter
    (fun (v : C.varinfo) ->
       match C.unrollType v.vtype with
       | C.TInt (ik, _) when C.bitsSizeOf v.vtype = 8 && not (C.isSigned ik) ->
         let h = Hashtbl.find homes v.vid in
         emit ctx (alu R.And h h (R.Imm 0xFF))
       | _ -> ())
    fd.sformals;
  List.iter (gen_stmt ctx) fd.sbody.bstmts;
  place ctx ctx.func_end;
  resolve (List.rev ctx.rev_frags)
;;
