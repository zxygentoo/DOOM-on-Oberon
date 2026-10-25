module C = GoblintCil
module R = Emu.Risc5_isa
module L = Linker

let unsupported = Check.unsupported
let internal = Check.internal

let is_unsigned_int (t : C.typ) =
  match C.unrollType t with
  | C.TInt (ik, _) -> not (C.isSigned ik)
  | _ -> false
;;

type reg = int

let return_reg = 0
let max_reg = 11
let first_callee_saved = 6
let fp_reg = 12 (* FP = entry SP: incoming stack args at FP+16.. *)
let db_reg = 13 (* DB: set once by crt0, never written *)
let sp_reg = 14
let lnk_reg = 15

type ctx =
  { mutable rev_frags : L.frag list
  ; homes : (int, reg) Hashtbl.t (* vid -> home register *)
  ; slots : (int, int) Hashtbl.t
    (* vid -> offset in the locals region: aggregates, address-taken scalars, spilled
       locals and params *)
  ; slots_base : int (* SP-offset of the locals region *)
  ; div_base : int
    (* SP-offset of the div area (helper-call staging: 2 operand words + up to 6
       scratch saves); -1 when the pre-scan found no helper, so a stray one fails loud *)
  ; globals : Globals.t
  ; scratch_lo : reg (* the pool is R[scratch_lo..scratch_hi], minus [home_regs] *)
  ; scratch_hi : reg
  ; scratch_free : bool array
  ; home_regs : bool array
    (* homes inside the scratch range (split shape): never pool registers *)
  ; mutable next_label : int
  ; mutable loops : (int option * int) list
    (* enclosing loops/switches, innermost first: (continue, break) targets. A switch
       has no continue ([None]), so a continue passes through to the loop above. *)
  ; stmt_labels : (int, int) Hashtbl.t
    (* sid -> label, for jump-target statements (case/default, goto targets) *)
  ; func_end : int
  ; is_vararg : bool
  ; n_formals : int
    (* va_start anchors at FP + 4*n_formals: callers store every argument to memory,
       so the variadic ones follow the named ones there (ABI §3) *)
  ; mutable max_used : reg
    (* highest register written: the save set is R[first_callee_saved..max_used] *)
  }

let emit ctx i = ctx.rev_frags <- L.Ins i :: ctx.rev_frags

let new_label ctx =
  let l = ctx.next_label in
  ctx.next_label <- l + 1;
  l
;;

let place ctx l = ctx.rev_frags <- L.Label l :: ctx.rev_frags

(* keyed by [sid], so a forward jump and its later-placed target agree *)
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

(* Not a refusal: [compile] catches it and retries over a three-address rewrite of
   the function ([flatten_fundec]). *)
exception Scratch_exhausted

let alloc_scratch ctx =
  let rec find r =
    if r > ctx.scratch_hi
    then raise Scratch_exhausted
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

(* homes and DB are never freed, so every address consumer can "free the base"
   unconditionally *)
let is_scratch ctx r = r >= ctx.scratch_lo && r <= ctx.scratch_hi && not ctx.home_regs.(r)
let free_scratch ctx r = if is_scratch ctx r then ctx.scratch_free.(r) <- true

let home ctx (v : C.varinfo) =
  match Hashtbl.find_opt ctx.homes v.vid with
  | Some r -> r
  | None -> internal "unmapped local %s" v.vname
;;

let is_reg_local ctx (v : C.varinfo) = (not v.vglob) && not (Hashtbl.mem ctx.slots v.vid)

(* a skipped global refuses with its skip reason, landing on each function that
   touches it *)
let global_offset ctx (v : C.varinfo) =
  match Hashtbl.find_opt ctx.globals.Globals.offsets v.vid with
  | Some off -> off
  | None ->
    (match Hashtbl.find_opt ctx.globals.Globals.skipped v.vid with
     | Some why -> unsupported "%s" why
     | None -> unsupported "extern global without a definition")
;;

(* There is no halfword op, so a 16-bit access is composed from two byte ops — Half
   is its own case, not a size. The bool is signedness, for widening on a read. *)
type access =
  | Word
  | Byte of bool
  | Half of bool

(* The access width belongs to the access, not the value type: a bitfield lval's type
   is the declared uint32, which classify_scalar would make a Word — an STW that
   clobbers the neighboring fields on every write. *)
let rec final_bitfield : C.offset -> C.fieldinfo option = function
  | C.Field (fi, C.NoOffset) when fi.fbitfield <> None -> Some fi
  | C.Field (_, rest) | C.Index (_, rest) -> final_bitfield rest
  | C.NoOffset -> None
;;

let classify_scalar (lv : C.lval) : access =
  let t = C.unrollType (C.typeOfLval lv) in
  match t with
  | (C.TInt _ | C.TEnum _ | C.TPtr _) when C.bitsSizeOf t = 32 -> Word
  | C.TBuiltin_va_list _ -> Word (* one pointer into the caller's home area (ABI §3) *)
  | C.TInt (ik, _) when C.bitsSizeOf t = 8 -> Byte (C.isSigned ik)
  | C.TInt (ik, _) when C.bitsSizeOf t = 16 -> Half (C.isSigned ik)
  | C.TComp _ | C.TArray _ ->
    (* struct copies are intercepted in gen_instr, by-value struct args and returns
       refused at the call boundary *)
    unsupported "aggregate used as a scalar value — unexpected CIL shape"
  | C.TFloat _ -> unsupported "float (ABI §4: banned in blob v1)"
  | _ -> unsupported "memory access of unsupported type"
;;

let classify_access (lv : C.lval) : access =
  match final_bitfield (snd lv) with
  | Some fi when Check.byte_bitfield fi ->
    (* one byte at bitsOffset/8: LDB zero-extends an unsigned :8 for free; a signed
       :8 sign-extends like a signed char *)
    (match C.unrollType fi.ftype with
     | C.TInt (ik, _) -> Byte (C.isSigned ik)
     | _ -> unsupported "bitfield of a non-integer type — unexpected CIL shape")
  | Some _ -> unsupported "bitfield other than byte-aligned :8 (ABI §4)"
  | None -> classify_scalar lv
;;

(* A Word access's constant residual must be a multiple of 4. Every base gen_addr hands
   out is word-aligned (DB, SP, a pointer to its pointee's alignment), and LDW/STW drop
   the address's low two bits — so an unaligned residual (a packed struct's int at +1, or
   [a[1].x] over 5-byte packed elements) would silently read or write the aligned word
   around it. Halfwords compose from bytes and are immune. What this can't see: a word
   field of a packed struct reached through a pointer the program misaligned at run time
   — DOOM's packed WAD structs live in aligned zone buffers. *)
let check_word_offset off =
  if off land 3 <> 0
  then
    unsupported
      "misaligned word access at offset %d (LDW/STW drop the low address bits — a packed \
       struct?)"
      off
;;

let alu ?(u = false) ?(v = false) op a b operand : R.instr =
  R.Alu { op; u; v; a; b; operand }
;;

let mov_reg d s = alu R.Mov d 0 (R.Reg s)

(* MOV's immediate zero-extends: anything past 0xFFFF, negatives included, takes the
   2-word build *)
let load_const ctx d n =
  let n = n land 0xFFFF_FFFF in
  if n <= 0xFFFF
  then emit ctx (alu R.Mov d 0 (R.Imm n))
  else List.iter (emit ctx) (L.load_const_pair d n)
;;

(* RISC5 has no compare: flags come from an ALU write into a dead scratch, allocated
   and freed on the spot so it never widens a live range. SUB sets the relational
   flags; MOV sets N/Z, the truthiness test. *)
let flags_of_sub ctx a b =
  let s = alloc_scratch ctx in
  emit ctx (alu R.Sub s a (R.Reg b));
  free_scratch ctx s
;;

let flags_of_reg ctx r =
  let s = alloc_scratch ctx in
  emit ctx (mov_reg s r);
  free_scratch ctx s
;;

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

(* frees [r] when a new register is produced *)
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

let pointee_size (t : C.typ) =
  match C.unrollType t with
  | C.TPtr (elem, _) -> C.bitsSizeOf elem / 8
  | _ -> unsupported "pointer arithmetic on a non-pointer — unexpected CIL shape"
;;

(* Which runtime helper [e]'s top node lowers to, if any — the one authority shared by
   codegen and the [calls_runtime_helper] pre-scan that sizes the div area. Unsigned >>
   calls only for a variable count; ptr - ptr only for a non-pow-2 element size. *)
let runtime_helper_of (e : C.exp) : string option =
  match e with
  | C.BinOp (((C.Div | C.Mod) as op), _, _, t) ->
    Some
      (match op, is_unsigned_int t with
       | C.Div, false -> "__div"
       | C.Div, true -> "__udiv"
       | C.Mod, false -> "__mod"
       | _ -> "__umod")
  | C.BinOp (C.Shiftrt, _, e2, t)
    when is_unsigned_int t && C.getInteger (C.constFold true e2) = None -> Some "__lsr"
  | C.BinOp (C.MinusPP, e1, _, _) ->
    (try if pow2_log (pointee_size (C.typeOf e1)) = None then Some "__div" else None with
     | Check.Unsupported _ | C.SizeOfError _ ->
       (* codegen will refuse this expression itself, with the right message *)
       None)
  | _ -> None
;;

(* fresh register <- [p] + [delta]; frees [p] *)
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
    internal "division reached the two-register builder (gen_expr intercepts it)"
  | C.Lt | C.Gt | C.Le | C.Ge | C.Eq | C.Ne ->
    internal "comparison reached the two-register builder (gen_expr intercepts it)"
  | C.LAnd | C.LOr ->
    (* CIL lowers && and || to control flow; one that survives as a BinOp is refused *)
    unsupported "short-circuit && / || as a value"
  | C.PlusPI | C.IndexPI | C.MinusPI | C.MinusPP ->
    internal
      "pointer arithmetic reached the two-register builder (gen_expr intercepts it)"
;;

(* [narrow_to] returns a fresh register and frees [r] — for operands that may be a
   home; [narrow_home] rewrites a home in place. Unsigned masks; signed shifts the
   sign bit to bit 31 and back. *)
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

(* CIL lowers pointer </> to unsigned compares; with 24-bit addresses the sign bit is
   never set, so the unsigned condition is exact. *)
let compare_unsigned (e : C.exp) : bool =
  match C.unrollType (C.typeOf e) with
  | C.TInt (ik, _) -> not (C.isSigned ik)
  | C.TPtr _ -> true
  | _ -> false
;;

(* The (cond, neg) that holds iff [a op b], given the flags of SUB a,b. Signed reads
   the overflow-aware N≠V (Lt) and (N≠V)|Z (Le); unsigned reads the carry: after SUB,
   C is set on borrow, i.e. iff a <u b — so below = Cs, below-or-same = Ls. *)
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

(* RISC5 has no set-on-condition: branch over two immediate loads. [d] is allocated
   only after the operands are freed, so it never widens their live range. *)
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
  | C.Const (C.CReal _) ->
    (* a floating constant only reaches codegen as a runtime value: under an int cast,
       a double one has already folded (the CastE case) — and a float or long double
       one deliberately doesn't (Globals.float_const) *)
    unsupported "float (ABI §4: banned in blob v1)"
  | C.Const (C.CStr (s, _)) ->
    (* DB + the literal's interned offset, the same address form as &global *)
    (match Hashtbl.find_opt ctx.globals.Globals.strings s with
     | Some off -> add_const ctx db_reg off
     | None ->
       unsupported "string literal not interned (data image past DB's +512 KB reach)")
  | C.Lval (C.Var v, C.NoOffset) when is_reg_local ctx v ->
    home ctx v (* a slotted local falls through to the load below *)
  | (C.AddrOf (C.Var f, C.NoOffset) | C.Lval (C.Var f, C.NoOffset))
    when C.isFunctionType (C.unrollType f.vtype) ->
    (* a function's address exists only after layout: an Addr frag *)
    let r = alloc_scratch ctx in
    ctx.rev_frags <- L.Addr (r, f.vname) :: ctx.rev_frags;
    r
  | C.Lval lv -> gen_load ctx lv
  | C.AddrOf lv | C.StartOf lv ->
    (* an address-taken variable is slotted, so a register local never gets here *)
    materialize_addr ctx lv
  | C.CastE (_, t, e') as whole ->
    Check.check_unsupported_types t;
    (* constant casts fold here — including a double expression under an int cast,
       (int)(1.02*FRACUNIT), so no float reaches run time *)
    (match Globals.int_core (C.constFold true whole) with
     | Some n ->
       let r = alloc_scratch ctx in
       load_const ctx r n;
       r
     | None ->
       if C.bitsSizeOf t >= 32
       then gen_expr ctx e' (* same-width or widening: the 32-bit value is unchanged *)
       else gen_narrow ctx t e')
  | C.UnOp (op, e', t) ->
    Check.check_unsupported_types t;
    gen_unop ctx op e'
  | C.BinOp (C.Shiftrt, e1, e2, t) when is_unsigned_int t ->
    (* logical >>: RISC5 has only ASR and ROR, so ROR by n, then mask off the n bits
       that wrapped to the top. The mask can exceed a 16-bit immediate (n = 1:
       0x7FFFFFFF); a variable count goes to the __lsr helper. *)
    (match C.getInteger (C.constFold true e2) with
     | Some c ->
       let n = C.Cilint.int_of_cilint c in
       if n = 0
       then gen_expr ctx e1
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
       gen_helper_call2
         ctx
         "__lsr"
         (fun () -> gen_expr ctx e1)
         (fun () -> gen_expr ctx e2))
  | C.BinOp (((C.PlusPI | C.IndexPI | C.MinusPI | C.MinusPP) as op), e1, e2, t) ->
    Check.check_unsupported_types t;
    gen_ptr_arith ctx op e1 e2
  | C.BinOp ((C.Div | C.Mod), e1, e2, t) as whole ->
    (* always a helper call (ABI §5): DIV floors where C truncates and takes only
       divisors in [1, 2^31-1]. The (already converted) result type picks the pair. *)
    Check.check_unsupported_types t;
    let name =
      match runtime_helper_of whole with
      | Some n -> n
      | None -> assert false (* Div/Mod always routes to a helper *)
    in
    gen_helper_call2 ctx name (fun () -> gen_expr ctx e1) (fun () -> gen_expr ctx e2)
  | C.BinOp (((C.Lt | C.Gt | C.Le | C.Ge | C.Eq | C.Ne) as op), e1, e2, t) ->
    (* a comparison as a value; as a condition it goes through gen_cond *)
    Check.check_unsupported_types t;
    let tcond, tneg =
      match rel_cond ~signed:(not (compare_unsigned e1)) op with
      | Some c -> c
      | None -> assert false (* the six relational ops all map *)
    in
    let r1 = gen_expr ctx e1 in
    let r2 = gen_expr ctx e2 in
    flags_of_sub ctx r1 r2;
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
  | (C.SizeOf _ | C.SizeOfE _ | C.SizeOfStr _) as e ->
    (* CIL leaves sizeof unfolded on purpose, so it folds here. The operand is never
       evaluated (only its type is taken), and there is no type check: sizeof of a
       banned type is still a valid number. *)
    let n =
      match e with
      | C.SizeOf t -> C.bitsSizeOf t / 8
      | C.SizeOfE e' -> C.bitsSizeOf (C.typeOf e') / 8
      | C.SizeOfStr s -> String.length s + 1 (* array size: interpreted bytes + NUL *)
      | _ -> assert false (* the outer pattern admits only the three sizeof forms *)
    in
    let r = alloc_scratch ctx in
    load_const ctx r n;
    r
  | _ -> unsupported "expression form not supported"

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
    let r = gen_expr ctx e' in
    let m = alloc_scratch ctx in
    load_const ctx m 0xFFFF_FFFF;
    let rd = alloc_scratch ctx in
    emit ctx (alu R.Xor rd r (R.Reg m));
    free_scratch ctx m;
    free_scratch ctx r;
    rd
  | C.LNot ->
    (* !x is (x == 0): MOV sets Z *)
    let r = gen_expr ctx e' in
    flags_of_reg ctx r;
    free_scratch ctx r;
    bool_from_flags ctx R.Eq false

(* A sub-word cast as a value. A store into a sub-word lval doesn't come here: STB
   truncates for free, and gen_store composes the halfword itself. *)
and gen_narrow ctx (t : C.typ) (e' : C.exp) : reg =
  match C.unrollType t with
  | C.TInt (C.IBool, _) ->
    (* _Bool is 8 bits wide, but converting to it is (x != 0), not a byte mask:
       (_Bool)256 is 1. CIL folds constant conversions itself; DOOM has no _Bool *)
    unsupported "conversion to _Bool (nonzero becomes 1, not a byte mask) — none in DOOM"
  | C.TInt (ik, _) when C.bitsSizeOf t = 8 || C.bitsSizeOf t = 16 ->
    narrow_to ctx (gen_expr ctx e') ~bits:(C.bitsSizeOf t) ~signed:(C.isSigned ik)
  | _ -> unsupported "narrowing cast to a non-integer sub-word type"

(* ptr - ptr divides the byte gap by the element size: C guarantees both pointers
   index one array, so the gap is an exact multiple, and ASR of an exact multiple is
   the true quotient, negatives included. *)
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
    free_scratch ctx p1;
    free_scratch ctx p2;
    (match pow2_log size with
     | Some 0 -> d (* char*: byte gap already is the count *)
     | Some k ->
       emit ctx (alu R.Asr d d (R.Imm k));
       d
     | None ->
       (* exact division is sign-safe through __div: floored = truncated when the
          remainder is 0 *)
       gen_helper_call2
         ctx
         "__div"
         (fun () -> d)
         (fun () ->
            let c = alloc_scratch ctx in
            load_const ctx c size;
            c))
  | _ -> internal "gen_ptr_arith: non-pointer op"

(* A 2-arg runtime helper called from inside an expression. CIL's "no calls in
   expressions" covers only source calls; this BL is the backend's, so live temporaries
   in caller-saved scratch must survive it by hand, through the div area. Both operands
   are evaluated first (a nested helper call completes its own use of the area before
   ours begins), stored and freed — no swap puzzle when they sit in R1/R0 — then every
   still-busy scratch is saved, R0/R1 loaded, the BL made, the result parked in a fresh
   register, and the saves restored. *)
and gen_helper_call2 ctx name (gen_a : unit -> reg) (gen_b : unit -> reg) : reg =
  if ctx.div_base < 0 then internal "helper call without a div area (pre-scan mismatch)";
  let ra = gen_a () in
  let rb = gen_b () in
  emit ctx (R.Store { size = R.W; a = ra; base = sp_reg; off = ctx.div_base });
  emit ctx (R.Store { size = R.W; a = rb; base = sp_reg; off = ctx.div_base + 4 });
  free_scratch ctx ra;
  free_scratch ctx rb;
  (* only busy caller-saved scratches (R0-R5) need saving: anything in R6-R11
     survives by the helpers' ABI §5 contract. has_div forces the split shape, so no
     compact home sits below R6. *)
  let busy =
    List.filter
      (fun r -> r < first_callee_saved && not ctx.scratch_free.(r))
      (List.init (ctx.scratch_hi - ctx.scratch_lo + 1) (fun i -> ctx.scratch_lo + i))
  in
  List.iteri
    (fun i r ->
       emit
         ctx
         (R.Store { size = R.W; a = r; base = sp_reg; off = ctx.div_base + 8 + (4 * i) }))
    busy;
  emit ctx (R.Load { size = R.W; a = 0; base = sp_reg; off = ctx.div_base });
  emit ctx (R.Load { size = R.W; a = 1; base = sp_reg; off = ctx.div_base + 4 });
  call ctx name;
  let rd = alloc_scratch ctx in
  if rd <> return_reg then emit ctx (mov_reg rd return_reg);
  List.iteri
    (fun i r ->
       emit
         ctx
         (R.Load { size = R.W; a = r; base = sp_reg; off = ctx.div_base + 8 + (4 * i) }))
    busy;
  rd

(* Fold an lval into (base register, residual constant). Fields and constant indexes
   accumulate in the residual, which rides free in the mem-op's 20-bit offset, so p->f
   and a[3] stay one instruction. The caller does the access and frees the base
   (a no-op for DB and homes). *)
and gen_addr ctx ((host, off) : C.lval) : reg * int =
  let rec fold base residual (t : C.typ) (o : C.offset) =
    match o with
    | C.NoOffset -> base, residual
    | C.Field (fi, rest) ->
      (* guarded here too, not just at declarations: a cast pointer can reach a struct
         no declaration check saw *)
      if fi.fbitfield <> None && not (Check.byte_bitfield fi)
      then unsupported "bitfield other than byte-aligned :8 (ABI §4)";
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
      (* a slotted local: SP-relative, the mirror of a global's DB-relative base *)
      (match Hashtbl.find_opt ctx.slots v.vid with
       | Some off -> sp_reg, ctx.slots_base + off, v.vtype
       | None -> internal "local %s used as memory but has no slot" v.vname)
    | C.Mem e ->
      let pointee =
        match C.unrollType (C.typeOf e) with
        | C.TPtr (t, _) -> t
        | _ -> unsupported "deref of a non-pointer — unexpected CIL shape"
      in
      gen_expr ctx e, 0, pointee
  in
  let base, residual = fold base residual host_t off in
  (* the mem-op offset is 20-bit signed, [-0x80000, 0x7FFFF] — less one byte at the top:
     a halfword access also emits off + 1 (its high byte), which at 0x7FFFF would
     wrap to -0x80000 *)
  if residual >= -0x80000 && residual <= 0x7FFFE
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

(* The address as a value. Access reaches ±512 KB through the 20-bit mem-op offset,
   but forming an address past 64 K needs the constant built first. *)
and materialize_addr ctx (lv : C.lval) : reg =
  let base, off = gen_addr ctx lv in
  if off = 0 && is_scratch ctx base
  then base
  else if off >= 0 && off <= 0xFFFF
  then (
    (* one instruction reads base then writes d, so d may reuse base's register *)
    free_scratch ctx base;
    let d = alloc_scratch ctx in
    if off = 0 then emit ctx (mov_reg d base) else emit ctx (alu R.Add d base (R.Imm off));
    d)
  else (
    (* the constant takes two instructions, so it needs a register distinct from
       base, and base stays live until it stands (freeing base first let load_const
       land on it and the ADD doubled the offset — jig sample biga). d may reuse
       either: the ADD is one instruction. *)
    let c = alloc_scratch ctx in
    load_const ctx c off;
    free_scratch ctx c;
    free_scratch ctx base;
    let d = alloc_scratch ctx in
    emit ctx (alu R.Add d base (R.Reg c));
    d)

and gen_load ctx (lv : C.lval) : reg =
  let acc = classify_access lv in
  let base, off = gen_addr ctx lv in
  match acc with
  | Word ->
    check_word_offset off;
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
    (* (hi<<8) | lo from two LDBs, little-endian; base held across both *)
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

(* A halfword stores as two STB: the low byte, then ASR 8 — STB keeps only the low 8
   bits, so the sign the ASR smears in is harmless. *)
let gen_store ctx (lv : C.lval) (r : reg) : unit =
  let acc = classify_access lv in
  let base, off = gen_addr ctx lv in
  (match acc with
   | Word ->
     check_word_offset off;
     emit ctx (R.Store { size = R.W; a = r; base; off })
   | Byte _ -> emit ctx (R.Store { size = R.B; a = r; base; off })
   | Half _ ->
     emit ctx (R.Store { size = R.B; a = r; base; off });
     let hi = alloc_scratch ctx in
     emit ctx (alu R.Asr hi r (R.Imm 8));
     emit ctx (R.Store { size = R.B; a = hi; base; off = off + 1 });
     free_scratch ctx hi);
  free_scratch ctx base
;;

(* A register local takes a MOV into its home (it has no address); everything else
   goes through memory. va_arg's destination lands here too: CIL leaves it
   register-homed. *)
let store_lval ctx (lv : C.lval) (r : reg) =
  match lv with
  | C.Var v, C.NoOffset when is_reg_local ctx v ->
    let h = home ctx v in
    if h <> r then emit ctx (mov_reg h r)
  | _ -> gen_store ctx lv r
;;

(* The stdarg builtins. va_start arrives with only the ap lval — we anchor on the
   callee's own formal count; va_arg arrives lowered to (ap, sizeof t, &dst); va_end
   vanishes. A va_list is one pointer into the caller's home area: va_start =
   FP + 4*n_formals, va_arg loads a word and advances — default promotions make every
   legal variadic argument one word. *)
let is_va_builtin (f : C.varinfo) = String.starts_with ~prefix:"__builtin_va_" f.vname

let gen_va_builtin ctx name (args : C.exp list) =
  let as_ap e =
    match e with
    | C.Lval lv -> lv
    | _ -> unsupported "va builtin: va_list argument is not an lval — unexpected shape"
  in
  match name, args with
  | "__builtin_va_start", [ ap ] ->
    if not ctx.is_vararg
    then unsupported "va_start in a non-variadic function — unexpected shape";
    let r = alloc_scratch ctx in
    emit ctx (alu R.Add r fp_reg (R.Imm (4 * ctx.n_formals)));
    store_lval ctx (as_ap ap) r;
    free_scratch ctx r
  | "__builtin_va_end", [ _ ] -> () (* nothing to release: ap is a plain pointer *)
  | "__builtin_va_copy", [ dst; src ] ->
    let r = gen_expr ctx (C.Lval (as_ap src)) in
    store_lval ctx (as_ap dst) r;
    free_scratch ctx r
  | "__builtin_va_arg", [ ap; size_e; dst_addr ] ->
    (match C.getInteger (C.constFold true size_e) with
     | Some c when C.Cilint.int_of_cilint c = 4 -> ()
     | Some _ ->
       unsupported
         "va_arg of a non-word type (variadic args promote to 4 bytes; ABI §4 bans \
          64-bit and double)"
     | None -> unsupported "va_arg: non-constant size — unexpected shape");
    let rec strip e =
      match e with
      | C.CastE (_, _, e') -> strip e'
      | e -> e
    in
    let dst_lv =
      match strip dst_addr with
      | C.AddrOf lv -> lv
      | _ -> unsupported "va_arg: destination is not &lval — unexpected shape"
    in
    let ap_lv = as_ap ap in
    let p = gen_expr ctx (C.Lval ap_lv) in
    let v = alloc_scratch ctx in
    emit ctx (R.Load { size = R.W; a = v; base = p; off = 0 });
    store_lval ctx dst_lv v;
    free_scratch ctx v;
    (* ap += 4, via a fresh register: [p] may BE ap's home — never mutate in place *)
    let p2 = alloc_scratch ctx in
    emit ctx (alu R.Add p2 p (R.Imm 4));
    free_scratch ctx p;
    store_lval ctx ap_lv p2;
    free_scratch ctx p2
  | _ -> unsupported "stdarg builtin %s — unexpected shape" name
;;

(* [dst = src] for struct-typed lvals, byte by byte: these structs are often
   sub-word-aligned (mapthing_t is align 2, struct color align 1), and LDW/STW would
   mask the address. Cold in DOOM, so two ops per byte is fine. *)
let gen_struct_copy ctx (dst : C.lval) (src : C.lval) (size : int) : unit =
  if size > 0x80000
  then unsupported "struct copy of %d B (past the 20-bit mem-op offset)" size;
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

let gen_instr ctx (i : C.instr) =
  match i with
  | C.Set (dst, e, _, _)
    when match C.unrollType (C.typeOfLval dst) with
         | C.TComp _ | C.TArray _ -> true
         | _ -> false ->
    (* a struct-typed Set is a by-value copy; its RHS is the source lval *)
    let src =
      match e with
      | C.Lval src -> src
      | _ -> unsupported "aggregate assignment from a non-lval — unexpected CIL shape"
    in
    gen_struct_copy ctx dst src (C.bitsSizeOf (C.typeOfLval dst) / 8)
  | C.Set (lv, e, _, _) ->
    let r = gen_expr ctx e in
    store_lval ctx lv r;
    free_scratch ctx r
  | C.Call (_, C.Lval (C.Var f, C.NoOffset), args, _, _) when is_va_builtin f ->
    (* stdarg builtins inline — they must never become real calls (a BL to va_start
       would clobber the very registers and stack shape it is asking about) *)
    gen_va_builtin ctx f.vname args
  | C.Call (lvopt, fexp, args, _, _) ->
    (* Args go through the outgoing area: each is evaluated with the full scratch pool and
       stored to SP+4i, then R0-R3 load from the first four slots. Evaluation and
       register placement decouple, so no half-loaded arg register is clobbered; args
       5+ stay where they were stored (the callee's FP+16..), and the home area stays
       populated — what a varargs callee reads. *)
    (match C.unrollType (C.typeOf fexp) with
     | C.TFun (rt, _, _, _) ->
       (match C.unrollType rt with
        | C.TComp _ | C.TArray _ ->
          unsupported
            "aggregate return by value (ABI §3's hidden pointer is unimplemented)"
        | C.TFloat _ -> unsupported "float return (ABI §4: banned)"
        | _ -> ())
     | _ -> ());
    List.iter
      (fun a ->
         match C.unrollType (C.typeOf a) with
         | C.TComp _ | C.TArray _ ->
           unsupported
             "aggregate call argument by value (ABI §3's stack copy is unimplemented)"
         | C.TFloat _ -> unsupported "float arg (ABI §4: banned)"
         | _ -> ())
      args;
    List.iteri
      (fun i a ->
         let r = gen_expr ctx a in
         emit ctx (R.Store { size = R.W; a = r; base = sp_reg; off = 4 * i });
         free_scratch ctx r)
      args;
    (* an indirect target is evaluated after the arg stores but before the R0-R3
       loads, with R0-R3 claimed so it lands above them; a helper call inside it saves
       and restores the claimed registers harmlessly — the args are still in memory *)
    let do_call =
      match fexp with
      | C.Lval (C.Var f, C.NoOffset)
        when match C.unrollType f.vtype with
             | C.TFun _ -> true
             | _ -> false -> fun () -> call ctx f.vname
      | C.Lval (C.Mem e, C.NoOffset) ->
        List.iter (fun r -> ctx.scratch_free.(r) <- false) [ 0; 1; 2; 3 ];
        let ft = gen_expr ctx e in
        fun () ->
          emit
            ctx
            (R.Branch { cond = R.True; neg = false; link = true; target = R.To_reg ft });
          free_scratch ctx ft;
          List.iter (fun r -> ctx.scratch_free.(r) <- true) [ 0; 1; 2; 3 ]
      | _ ->
        unsupported "call through a non-lval function expression — unexpected CIL shape"
    in
    List.iteri
      (fun i _ ->
         if i < 4 then emit ctx (R.Load { size = R.W; a = i; base = sp_reg; off = 4 * i }))
      args;
    do_call ();
    (match lvopt with
     | None -> ()
     | Some (C.Var v, C.NoOffset) when is_reg_local ctx v ->
       let h = home ctx v in
       if h <> return_reg then emit ctx (mov_reg h return_reg)
     | Some lv ->
       (* the result sits in R0, the first scratch the destination's address would take
          (or a helper call inside it would clobber): claim it for the store, so gen_addr
          allocates from R1 *)
       ctx.scratch_free.(return_reg) <- false;
       gen_store ctx lv return_reg;
       free_scratch ctx return_reg)
  | C.VarDecl _ -> ()
  | C.Asm _ -> unsupported "inline asm"
;;

let gen_cond ctx (cond : C.exp) ~(false_label : int) =
  (* fallback: treat [cond] as a value, false iff zero (the register write sets Z) *)
  let truthy () =
    let r = gen_expr ctx cond in
    flags_of_reg ctx r;
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
       flags_of_sub ctx r1 r2;
       free_scratch ctx r1;
       free_scratch ctx r2;
       (* jump when the comparison is FALSE: {tcond, not tneg} *)
       bcc ctx tcond (not tneg) false_label)
  | _ -> truthy ()
;;

let rec gen_stmt ctx (s : C.stmt) =
  (* a jump target's label goes here, ahead of its body *)
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
    (* a compare-and-branch chain; the case labels ride on the body statements, so
       fall-through is plain statement order. No continue target ([None]). *)
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
                flags_of_sub ctx r vr;
                free_scratch ctx vr;
                bcc ctx R.Eq false l
              | C.Default _ -> default := Some l
              | C.CaseRange _ -> unsupported "case ranges (GCC extension)"
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
    (* the nearest enclosing loop's top. CIL lowers a for-loop's continue to a goto
       before the increment, so that one arrives as a Goto *)
    let rec loop_cont = function
      | (Some c, _) :: _ -> jmp ctx c
      | (None, _) :: rest -> loop_cont rest
      | [] -> unsupported "continue outside a loop — unexpected CIL shape"
    in
    loop_cont ctx.loops
  | C.Goto (target, _) -> jmp ctx (label_of_stmt ctx !target)
  | C.ComputedGoto _ -> unsupported "computed goto (GCC &&label)"
;;

(* [None] for a leaf, else [Some n], the widest call's argument count — it sizes the
   4*max(4,n)-byte outgoing area. *)
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

(* A helper call makes a function non-leaf and gives it a div area. Division hides in
   any expression position, so this is a visitor, not a statement walk. *)
let calls_runtime_helper (fd : C.fundec) : bool =
  let found = ref false in
  let scan =
    object
      inherit C.nopCilVisitor

      method! vexpr e =
        if runtime_helper_of e <> None then found := true;
        C.DoChildren
    end
  in
  ignore (C.visitCilFunction scan fd);
  !found
;;

(* The scratch-exhaustion retry: rewrite the body so every statement is
   tmp = atom op atom. The temporaries are ordinary locals — homes or spill slots — so
   no flattened statement needs more than a few scratches. Only functions that exhaust
   the pool pay for it. Statements are mutated in place, so goto targets and switch
   cases stay valid, and a hoisted prelude lands under the original statement's label —
   correct: jumping there must re-evaluate the operands. *)
let flatten_fundec (fd : C.fundec) : unit =
  (* compiles holding at most a scratch or two *)
  let is_atom (e : C.exp) : bool =
    match e with
    | C.Const _ | C.SizeOf _ | C.SizeOfE _ | C.SizeOfStr _ -> true
    | C.Lval (C.Var _, C.NoOffset) -> true
    | C.CastE (_, _, C.Lval (C.Var _, C.NoOffset)) | C.CastE (_, _, C.Const _) -> true
    | _ -> false
  in
  let prelude : C.instr list ref = ref [] in
  let hoist loc (e : C.exp) : C.exp =
    let tmp = C.makeTempVar fd ~name:"__ta" (C.typeOf e) in
    prelude := C.Set ((C.Var tmp, C.NoOffset), e, loc, loc) :: !prelude;
    C.Lval (C.Var tmp, C.NoOffset)
  in
  (* [flat] returns an ATOM (hoisting a shallowed node if needed); [shallow]
     rewrites one operator level over atomized children — the form a statement's
     top node is allowed to keep *)
  let rec flat loc (e : C.exp) : C.exp =
    if is_atom e then e else hoist loc (shallow loc e)
  and shallow loc (e : C.exp) : C.exp =
    match e with
    | C.BinOp (op, a, b, t) -> C.BinOp (op, flat loc a, flat loc b, t)
    | C.UnOp (op, a, t) -> C.UnOp (op, flat loc a, t)
    | C.CastE (k, t, a) -> C.CastE (k, t, flat loc a)
    | C.Lval lv -> C.Lval (flat_lval loc lv)
    | C.AddrOf lv -> C.AddrOf (flat_lval loc lv)
    | C.StartOf lv -> C.StartOf (flat_lval loc lv)
    | e -> e (* atoms and shapes codegen refuses regardless *)
  (* an lval keeps its structure (a struct copy must stay a copy; AddrOf needs
     the lval itself) — only the embedded address math atomizes *)
  and flat_lval loc ((host, off) : C.lval) : C.lval =
    let host' =
      match host with
      | C.Mem e -> C.Mem (flat loc e)
      | C.Var _ as v -> v
    in
    host', flat_off loc off
  and flat_off loc (o : C.offset) : C.offset =
    match o with
    | C.NoOffset -> C.NoOffset
    | C.Field (f, rest) -> C.Field (f, flat_off loc rest)
    | C.Index (e, rest) -> C.Index (flat loc e, flat_off loc rest)
  in
  let do_instr (i : C.instr) : C.instr list =
    prelude := [];
    let i' =
      match i with
      | C.Set (lv, e, loc, eloc) -> C.Set (flat_lval loc lv, shallow loc e, loc, eloc)
      | C.Call (_, C.Lval (C.Var f, C.NoOffset), _, _, _) when is_va_builtin f ->
        (* untouched: gen_va_builtin matches their exact shape — va_arg's &dst must
           stay an AddrOf (CIL leaves dst register-homed, no slot), and hoisting it
           into a temp would ask for the address of a register. Their args are
           cheap already: ap, a sizeof, &dst *)
        i
      | C.Call (ret, f, args, loc, eloc) ->
        (* args become full atoms: the marshaller loads them while R0-R3 (and an
           indirect target) are claimed, so no arg may need deep evaluation *)
        let f' =
          match f with
          | C.Lval (C.Var _, C.NoOffset) -> f
          | C.Lval lv -> C.Lval (flat_lval loc lv)
          | e -> e
        in
        C.Call (Option.map (flat_lval loc) ret, f', List.map (flat loc) args, loc, eloc)
      | i -> i
    in
    List.rev !prelude @ [ i' ]
  in
  let flat_top loc (e : C.exp) : C.instr list * C.exp =
    prelude := [];
    let e' = shallow loc e in
    List.rev !prelude, e'
  in
  (* mutated in place, so labels and case markers stay on the statement *)
  let rewrap pre k =
    if pre = [] then k else C.Block (C.mkBlock [ C.mkStmt (C.Instr pre); C.mkStmt k ])
  in
  let rec do_stmt (s : C.stmt) : unit =
    match s.skind with
    | C.Instr il -> s.skind <- C.Instr (List.concat_map do_instr il)
    | C.If (e, b1, b2, l1, l2) ->
      do_block b1;
      do_block b2;
      let pre, e' = flat_top l1 e in
      s.skind <- rewrap pre (C.If (e', b1, b2, l1, l2))
    | C.Switch (e, b, cases, l1, l2) ->
      do_block b;
      let pre, e' = flat_top l1 e in
      s.skind <- rewrap pre (C.Switch (e', b, cases, l1, l2))
    | C.Return (Some e, loc, eloc) ->
      let pre, e' = flat_top loc e in
      s.skind <- rewrap pre (C.Return (Some e', loc, eloc))
    | C.Block b | C.Loop (b, _, _, _, _) -> do_block b
    | _ -> ()
  and do_block (b : C.block) : unit = List.iter do_stmt b.bstmts in
  do_block fd.sbody
;;

let compile_once ~(globals : Globals.t) (fd : C.fundec) : L.obj =
  let return_type =
    match fd.svar.vtype with
    | C.TFun (rt, _, _, _) -> rt
    | t -> t
  in
  Check.check_unsupported_types return_type;
  List.iter
    (fun (v : C.varinfo) -> Check.check_unsupported_types v.vtype)
    (fd.sformals @ fd.slocals);
  (* CIL leaves every sid at -1 until a CFG pass; jump-target labels are keyed by sid,
     so number the statements ourselves. Switch cases and goto targets are the same
     physical statements as the body's. *)
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
  (match C.unrollType return_type with
   | C.TComp _ | C.TArray _ ->
     unsupported "aggregate return by value (ABI §3's hidden pointer is unimplemented)"
   | _ -> ());
  List.iter
    (fun (v : C.varinfo) ->
       match C.unrollType v.vtype with
       | C.TComp _ | C.TArray _ ->
         unsupported "aggregate parameter by value (ABI §3's stack copy is unimplemented)"
       | _ -> ())
    fd.sformals;
  let call_info = call_arity fd in
  (* a helper BL makes the function non-leaf even with no source calls; the helpers are
     frame-less leaves, so no outgoing area is owed for them *)
  let has_div = calls_runtime_helper fd in
  let leaf = call_info = None && not has_div in
  (* args 5+ arrive on the stack, read at FP+16..; a variadic callee always needs FP
     (va_start) *)
  let is_vararg =
    match C.unrollType fd.svar.vtype with
    | C.TFun (_, _, va, _) -> va
    | _ -> false
  in
  let needs_fp = List.length fd.sformals > 4 || is_vararg in
  let outgoing_area =
    match call_info with
    | None -> 0
    | Some n -> 4 * max 4 n
  in
  (* aggregates and address-taken scalars get a frame slot. SP-relative, because the
     offset must be known before body codegen fixes the save set — an FP-relative
     offset subtracts the frame size *)
  let slots = Hashtbl.create 8 in
  let locals_size = ref 0 in
  let needs_slot (v : C.varinfo) =
    v.vaddrof
    ||
    match C.unrollType v.vtype with
    | C.TComp _ | C.TArray _ -> true
    | _ -> false
  in
  let add_slot (v : C.varinfo) =
    Hashtbl.replace slots v.vid !locals_size;
    (* round each slot up to a word so the next stays 4-aligned (ABI §4) *)
    locals_size := !locals_size + (((C.bitsSizeOf v.vtype / 8) + 3) land lnot 3)
  in
  let alloc_slot (v : C.varinfo) = if needs_slot v then add_slot v in
  List.iter alloc_slot fd.sformals;
  List.iter alloc_slot fd.slocals;
  (* Every function gets at least six scratch registers. The compact shape — homes from
     R0, scratch above, a zero-cost frame — is kept only for leaves with <= 6 register
     candidates. Everything else takes the split shape: homes in callee-saved R6-R11,
     locals and params past six spill to slots, and scratch widens to R0-R5 plus every
     unused home register — sound because a busy scratch in R6-R11 is callee-saved, and
     the helper-call protocol saves whatever is busy below R6. *)
  let n_candidates =
    List.length fd.sformals
    + List.length
        (List.filter (fun (v : C.varinfo) -> not (Hashtbl.mem slots v.vid)) fd.slocals)
  in
  let compact = leaf && n_candidates <= first_callee_saved in
  let home_base = if compact then 0 else first_callee_saved in
  let homes = Hashtbl.create 16 in
  let next = ref home_base in
  let assign (v : C.varinfo) =
    Hashtbl.replace homes v.vid !next;
    incr next
  in
  (* params: a home while they fit (an address-taken one keeps its arrival register,
     spilled to the slot by the prologue); past that, slot-only — necessarily index
     >= 6, so they arrived on the stack *)
  List.iter
    (fun (v : C.varinfo) ->
       if !next <= max_reg
       then assign v
       else if not (Hashtbl.mem slots v.vid)
       then add_slot v)
    fd.sformals;
  (* locals: a home while they fit, else a spill slot *)
  List.iter
    (fun (v : C.varinfo) ->
       if not (Hashtbl.mem slots v.vid)
       then if !next <= max_reg then assign v else add_slot v)
    fd.slocals;
  let scratch_lo, scratch_hi = if compact then !next, max_reg else 0, max_reg in
  (* the div area: 2 operand words + at most six caller-saved scratch saves *)
  let div_area = if has_div then 32 else 0 in
  let slots_base = outgoing_area + div_area in
  let ctx =
    { rev_frags = []
    ; homes
    ; slots
    ; slots_base
    ; div_base = (if has_div then outgoing_area else -1)
    ; globals
    ; scratch_lo
    ; scratch_hi
    ; scratch_free =
        (let a = Array.make (max_reg + 1) true in
         if not compact then Hashtbl.iter (fun _ r -> a.(r) <- false) homes;
         a)
    ; home_regs =
        (let a = Array.make (max_reg + 1) false in
         if not compact then Hashtbl.iter (fun _ r -> a.(r) <- true) homes;
         a)
    ; next_label = 1 (* label 0 is func_end *)
    ; loops = []
    ; stmt_labels = Hashtbl.create 16
    ; func_end = 0
    ; is_vararg
    ; n_formals = List.length fd.sformals
    ; max_used =
        !next - 1 (* the last home; scratch (and so the save set) grow from here *)
    }
  in
  (* a sub-word param arrives as a full word: narrow its home to the declared width
     (the caller passes the raw int). A slotted param is skipped — its slot's sub-word
     load narrows on read *)
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
  (* The frame, built after the body because only now is the save set (max_used)
     known. SP-relative, low to high: outgoing area · div area · locals region ·
     callee-saved R[6..max_used] · FP (needs_fp) · LNK (non-leaf). A leaf touching only
     R0-R5 with no slots gets frame = 0: no SUB/ADD SP, just B LNK. *)
  let saved =
    List.init
      (max 0 (ctx.max_used - first_callee_saved + 1))
      (fun i -> first_callee_saved + i)
  in
  let saves_base = slots_base + !locals_size in
  let saves_end = saves_base + (4 * List.length saved) in
  let fp_off = saves_end in
  let lnk_off = saves_end + if needs_fp then 4 else 0 in
  let frame = lnk_off + if leaf then 0 else 4 in
  (* SUB SP / ADD SP / FP = SP + frame carry the frame as an ALU immediate — a raw
     16-bit field (risc5_isa masks the rest silently): a bigger frame would open short
     of its own saves and locals and write into the caller's *)
  if frame > 0xFFFF
  then unsupported "stack frame of %d B (SUB SP takes a 16-bit immediate)" frame;
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
  (* prologue: open the frame, save callee-saved (+ FP, + LNK) before anything
     overwrites them, set FP = entry SP, then move params to their homes — args 1-4
     from R0-R3, args 5+ from FP+16.. *)
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
                match Hashtbl.find_opt homes v.vid, Hashtbl.find_opt slots v.vid with
                | Some h, slot_opt ->
                  let place =
                    if i < 4
                    then
                      if compact
                      then [] (* compact: the home IS the arrival register Ri *)
                      else [ L.Ins (mov_reg h i) ]
                    else
                      [ L.Ins (R.Load { size = R.W; a = h; base = fp_reg; off = 4 * i }) ]
                  in
                  (* an address-taken param: once in its home, spill it to its slot — the
                     slot is its canonical location *)
                  let spill =
                    match slot_opt with
                    | Some off ->
                      [ L.Ins
                          (R.Store
                             { size = R.W; a = h; base = sp_reg; off = slots_base + off })
                      ]
                    | None -> []
                  in
                  place @ spill
                | None, Some off ->
                  (* a spilled param goes straight to its slot. In practice i >= 6, so it
                     arrived on the stack; R5 is a safe shuttle this early *)
                  if i < 4
                  then
                    [ L.Ins
                        (R.Store
                           { size = R.W; a = i; base = sp_reg; off = slots_base + off })
                    ]
                  else
                    [ L.Ins (R.Load { size = R.W; a = 5; base = fp_reg; off = 4 * i })
                    ; L.Ins
                        (R.Store
                           { size = R.W; a = 5; base = sp_reg; off = slots_base + off })
                    ]
                | None, None -> assert false (* every formal is homed or slotted *))
             fd.sformals)
      in
      (L.Ins (alu R.Sub sp_reg sp_reg (R.Imm frame)) :: saves)
      @ fp_setup
      @ lnk_save
      @ param_setup)
  in
  { L.name = fd.svar.vname; frags = prologue @ List.rev ctx.rev_frags }
;;

let compile ~globals (fd : C.fundec) : L.obj =
  try compile_once ~globals fd with
  | Scratch_exhausted ->
    (* the three-address retry *)
    flatten_fundec fd;
    (try compile_once ~globals fd with
     | Scratch_exhausted ->
       internal "out of registers even after three-address flattening")
;;
