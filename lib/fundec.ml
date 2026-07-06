(* Per-function compilation (AGENT.md 1b): one CIL fundec -> its Risc5_isa.instr list,
   for integer *leaf* functions — straight-line code, if/while/for control flow
   (comparisons lower to SUB + a conditional branch; [resolve] lays the branches out to
   PC-relative offsets), and 32-bit scalar globals/statics (DB-relative one-instr
   LDW/STW off a [Globals.t], ABI §2/§6). The minimal vertical the differential jig
   exercises. Naive register allocation (ABI §2: a leaf may use R0-R11 freely; args and
   return in R0..) — every variable keeps a fixed home register, so control-flow merge
   points need no reconciliation. Anything outside the supported subset raises
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

let is_scratch ctx r = r >= ctx.base_scratch
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
    unsupported "pointer arithmetic — memory slice s3.2"
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
  | C.Lval (C.Var v, C.NoOffset) when v.vglob ->
    (* a 32-bit scalar global/static: one LDW off DB (ABI §2/§6) — layout admitted
       word scalars only, so W is the right size by construction *)
    let r = alloc_scratch ctx in
    emit ctx (R.Load { size = R.W; a = r; base = db_reg; off = global_offset ctx v });
    r
  | C.Lval (C.Var v, C.NoOffset) -> home ctx v
  | C.AddrOf (C.Var v, _) when not v.vglob ->
    unsupported "&local (needs a stack slot in the ABI §3 frame) — call slice"
  | C.AddrOf _ | C.StartOf _ ->
    unsupported "address-of / array-to-pointer decay — memory slice s3.2"
  | C.CastE (_, t, e') ->
    Check.check_unsupported_types t;
    if C.bitsSizeOf t < 32 then unsupported "narrowing cast to <32-bit — later slice";
    gen_expr ctx e' (* int<->int of the same width: the 32-bit value is unchanged *)
  | C.UnOp (op, e', t) ->
    Check.check_unsupported_types t;
    gen_unop ctx op e'
  | C.BinOp (C.Shiftrt, _, _, t) when is_unsigned_int t ->
    unsupported "unsigned >> (compiles to ROR + mask) — later slice"
  | C.BinOp (op, e1, e2, t) ->
    Check.check_unsupported_types t;
    let r1 = gen_expr ctx e1 in
    let r2 = gen_expr ctx e2 in
    let rd = alloc_scratch ctx in
    emit ctx (binop_instr op rd r1 r2);
    free_scratch ctx r1;
    free_scratch ctx r2;
    rd
  | C.Lval _ -> unsupported "lvalue through memory/field/index — memory slice s3.2"
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
  | C.LNot -> unsupported "logical ! (0/1 materialization) — later slice"
;;

(* ---- statements ---- *)
let gen_instr ctx (i : C.instr) =
  match i with
  | C.Set ((C.Var v, C.NoOffset), e, _, _) when v.vglob ->
    (* global = e: evaluate, then one STW off DB — the mirror of the load above *)
    let r = gen_expr ctx e in
    emit ctx (R.Store { size = R.W; a = r; base = db_reg; off = global_offset ctx v });
    free_scratch ctx r
  | C.Set ((C.Var v, C.NoOffset), e, _, _) ->
    let r = gen_expr ctx e in
    let h = home ctx v in
    if r <> h then emit ctx (mov_reg h r);
    free_scratch ctx r
  | C.Set _ -> unsupported "store through memory/field/index lvalue — memory slice s3.2"
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
  List.iter (gen_stmt ctx) fd.sbody.bstmts;
  place ctx ctx.func_end;
  resolve (List.rev ctx.rev_frags)
;;
