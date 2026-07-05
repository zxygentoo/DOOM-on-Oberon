(* Slice 1 of the RISC5 backend (AGENT.md 1b): CIL typed AST -> Risc5_isa.instr list, for
   straight-line integer *leaf* functions — the minimal vertical the differential jig
   exercises. Naive register allocation (ABI §2: a leaf may use R0-R11 freely; args and
   return sit in R0..). Anything outside the supported subset raises [Unsupported] — the
   pre-codegen gate (ABI §4 + the spikes/cil census) refuses to miscompile rather than
   guess. Each unsupported message names the later slice that will handle it. *)

module C = GoblintCil (* the CIL front-end AST *)
module R = Emu.Risc5_isa (* the RISC5 instruction encoding we emit *)

exception Unsupported of string

let unsupported fmt = Printf.ksprintf (fun s -> raise (Unsupported s)) fmt

(* ---- the ABI §4 gate: reject banned types (float / 64-bit / bitfield) up front ---- *)
let rec check_type (t : C.typ) =
  match t with
  | C.TInt ((C.ILongLong | C.IULongLong), _) ->
    unsupported "64-bit integer (ABI §4: no long long in the blob)"
  | C.TFloat _ -> unsupported "float (ABI §4: banned in blob v1)"
  | C.TNamed (ti, _) -> check_type ti.ttype
  | C.TComp (ci, _) ->
    List.iter
      (fun (f : C.fieldinfo) ->
        if f.fbitfield <> None then unsupported "bitfield (ABI §4: banned)";
        check_type f.ftype)
      ci.cfields
  | C.TArray (t', _, _) -> check_type t'
  | _ -> ()

let is_unsigned_int (t : C.typ) =
  match C.unrollType t with
  | C.TInt (ik, _) -> not (C.isSigned ik)
  | _ -> false

(* ---- registers (ABI §2). Leaf + straight-line ⇒ R0..R11 usable; R12-R15 = FP/DB/SP/LNK. ---- *)
type reg = int

let return_reg = 0
let max_reg = 11

type ctx =
  { mutable rev : R.instr list (* emitted instrs, reversed *)
  ; homes : (int, reg) Hashtbl.t (* varinfo.vid -> home register *)
  ; base_scratch : reg (* first register above the homes *)
  ; scratch_free : bool array (* is scratch register r free? (indexed by reg) *)
  }

let emit ctx i = ctx.rev <- i :: ctx.rev

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

let is_scratch ctx r = r >= ctx.base_scratch
let free_scratch ctx r = if is_scratch ctx r then ctx.scratch_free.(r) <- true

let home ctx (v : C.varinfo) =
  match Hashtbl.find_opt ctx.homes v.vid with
  | Some r -> r
  | None ->
    (* not a param/local ⇒ a global/static (CIL folds statics into globals): its home is a
       data-section address, not a register — that's the memory slice. *)
    if v.vglob
    then unsupported "global/static variable access — memory slice"
    else unsupported "unmapped local %s — internal error" v.vname

(* ---- instruction builders ---- *)
let alu ?(u = false) ?(v = false) op a b operand : R.instr =
  R.Alu { op; u; v; a; b; operand }

let mov_reg d s = alu R.Mov d 0 (R.Reg s) (* R[d] <- R[s] *)

(* R[d] <- 32-bit constant n: one MOV if it fits a zero-extended 16-bit immediate, else
   MOV-high (u=1: R[d] = hi<<16) + IOR-low (zero-extended) — the canonical RISC5 build. *)
let load_const ctx d n =
  let n = n land 0xFFFF_FFFF in
  let lo = n land 0xFFFF
  and hi = (n lsr 16) land 0xFFFF in
  if hi = 0
  then emit ctx (alu R.Mov d 0 (R.Imm lo))
  else begin
    emit ctx (alu ~u:true R.Mov d 0 (R.Imm hi));
    emit ctx (alu R.Ior d d (R.Imm lo))
  end

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
    unsupported "comparison/logical op needs flags + branch — control-flow slice"
  | C.PlusPI | C.IndexPI | C.MinusPI | C.MinusPP ->
    unsupported "pointer arithmetic — memory slice"

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
  | C.Lval (C.Var v, C.NoOffset) -> home ctx v
  | C.CastE (_, t, e') ->
    check_type t;
    if C.bitsSizeOf t < 32 then unsupported "narrowing cast to <32-bit — later slice";
    gen_expr ctx e' (* int<->int of the same width: the 32-bit value is unchanged *)
  | C.UnOp (op, e', t) ->
    check_type t;
    gen_unop ctx op e'
  | C.BinOp (C.Shiftrt, _, _, t) when is_unsigned_int t ->
    unsupported "unsigned >> (compiles to ROR + mask) — later slice"
  | C.BinOp (op, e1, e2, t) ->
    check_type t;
    let r1 = gen_expr ctx e1 in
    let r2 = gen_expr ctx e2 in
    let rd = alloc_scratch ctx in
    emit ctx (binop_instr op rd r1 r2);
    free_scratch ctx r1;
    free_scratch ctx r2;
    rd
  | C.Lval _ ->
    unsupported "lvalue: only local/param variables (no memory/fields) — memory slice"
  | _ -> unsupported "expression form not supported in slice 1"

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
  | C.LNot -> unsupported "logical ! needs a compare — control-flow slice"

(* ---- statements ---- *)
let gen_instr ctx (i : C.instr) =
  match i with
  | C.Set ((C.Var v, C.NoOffset), e, _, _) ->
    let r = gen_expr ctx e in
    let h = home ctx v in
    if r <> h then emit ctx (mov_reg h r);
    free_scratch ctx r
  | C.Set _ -> unsupported "store to a non-variable lvalue — memory slice"
  | C.Call _ -> unsupported "function call — call slice"
  | C.VarDecl _ -> ()
  | C.Asm _ -> unsupported "inline asm — n/a"

let rec gen_stmt ctx (s : C.stmt) =
  match s.skind with
  | C.Instr instrs -> List.iter (gen_instr ctx) instrs
  | C.Block b -> List.iter (gen_stmt ctx) b.bstmts
  | C.Return (Some e, _, _) ->
    let r = gen_expr ctx e in
    if r <> return_reg then emit ctx (mov_reg return_reg r);
    free_scratch ctx r
  | C.Return (None, _, _) -> ()
  | C.If _ | C.Loop _ | C.Switch _ | C.Goto _ | C.ComputedGoto _ | C.Break _ | C.Continue _
    -> unsupported "control flow — later slice"

(* ---- entry: a straight-line integer leaf -> its instr list (args in R0.., return R0) ---- *)
let compile_fundec (fd : C.fundec) : R.instr list =
  let return_type =
    match fd.svar.vtype with
    | C.TFun (rt, _, _, _) -> rt
    | t -> t
  in
  check_type return_type;
  List.iter (fun (v : C.varinfo) -> check_type v.vtype) (fd.sformals @ fd.slocals);
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
    { rev = []
    ; homes
    ; base_scratch = !next
    ; scratch_free = Array.make (max_reg + 1) true
    }
  in
  List.iter (gen_stmt ctx) fd.sbody.bstmts;
  List.rev ctx.rev
