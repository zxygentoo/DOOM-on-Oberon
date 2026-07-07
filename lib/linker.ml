(* The instr-level linker (ABI §6). See linker.mli. Two passes: (1) a base word offset per
   function, in layout order, building the symbol table; (2) resolve each function at its base
   — intra-function branches are PC-relative so the base cancels, calls need the callee's
   global offset. A RISC5 PC-relative branch at word A lands at A+1+off, so off = target-A-1
   (risc.ml) — identical to Fundec's old intra-function resolve, now over the whole program. *)

module R = Emu.Risc5_isa

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
  { code : R.instr list
  ; symbols : (string * int) list
  ; code_base : int
  }

(* The intrinsic registry (ABI §5, frozen: { FixedMul }). A Call to an intrinsic
   expands INLINE at resolve instead of becoming a BL: FixedMul is the machine's party
   trick (§1: MUL leaves the 64-bit product's high word in H, natively, in 2 cycles),
   and the expansion clobbers exactly R0, R1, H, flags — a strict subset of a call's
   clobber set, so callers cannot tell, except by being fast. Taking an intrinsic's
   ADDRESS is unsupported: there is no function to point at (sym_addr fails loud). *)
let intrinsic_width name = if name = "FixedMul" then Some 6 else None
let is_intrinsic name = intrinsic_width name <> None

let frag_width = function
  | Label _ -> 0
  | Ins _ | Bcc _ | Jmp _ -> 1
  | Call name ->
    (match intrinsic_width name with
     | Some w -> w
     | None -> 1)
  | Addr _ -> 2 (* MOV-high + IOR, fixed even for small addresses: deterministic layout *)
;;

let code_size o = List.fold_left (fun a f -> a + frag_width f) 0 o.frags

let sym_addr (img : image) name =
  match List.assoc_opt name img.symbols with
  | Some off -> img.code_base + (4 * off)
  | None ->
    Check.unsupported "address of undefined function %s — 3b linker / mini-libc" name
;;

let link ~(code_base : int) (objs : obj list) : image =
  (* pass 1: base offset per function *)
  let _, rev_syms =
    List.fold_left
      (fun (off, syms) o -> off + code_size o, (o.name, off) :: syms)
      (0, [])
      objs
  in
  let symbols = List.rev rev_syms in
  let sym name =
    match List.assoc_opt name symbols with
    | Some off -> off
    | None ->
      Check.unsupported "call to undefined function %s — 3b linker / mini-libc" name
  in
  (* pass 2: resolve one function at its base offset *)
  let resolve_obj o =
    let base = List.assoc o.name symbols in
    let addr = Hashtbl.create 16 in
    ignore
      (List.fold_left
         (fun a f ->
            (match f with
             | Label l -> Hashtbl.replace addr l a
             | _ -> ());
            a + frag_width f)
         base
         o.frags);
    let a = ref base in
    List.concat_map
      (fun f ->
         let here = !a in
         a := !a + frag_width f;
         let branch cond neg target =
           R.Branch { cond; neg; link = false; target = R.To_off (target - here - 1) }
         in
         match f with
         | Label _ -> []
         | Ins i -> [ i ]
         | Bcc (cond, neg, l) -> [ branch cond neg (Hashtbl.find addr l) ]
         | Jmp l -> [ branch R.True false (Hashtbl.find addr l) ]
         | Call "FixedMul" ->
           (* fixed_t product = (int64(a) * int64(b)) >> 16, without any 64-bit value:
              MUL computes the full 64-bit product (low -> R0, high -> H); the result
              is high<<16 | low>>>16 — the middle 32 bits, exactly the int cast of the
              arithmetic shift. ROR+AND is the logical >>16 (no LSR on RISC5, s5.2b). *)
           [ R.Alu { op = R.Mul; u = false; v = false; a = 0; b = 0; operand = R.Reg 1 }
           ; R.Alu { op = R.Mov; u = true; v = false; a = 1; b = 0; operand = R.Reg 0 }
           ; R.Alu { op = R.Lsl; u = false; v = false; a = 1; b = 1; operand = R.Imm 16 }
           ; R.Alu { op = R.Ror; u = false; v = false; a = 0; b = 0; operand = R.Imm 16 }
           ; R.Alu
               { op = R.And; u = false; v = false; a = 0; b = 0; operand = R.Imm 0xFFFF }
           ; R.Alu { op = R.Ior; u = false; v = false; a = 0; b = 1; operand = R.Reg 0 }
           ]
         | Call name ->
           [ R.Branch
               { cond = R.True
               ; neg = false
               ; link = true
               ; target = R.To_off (sym name - here - 1)
               }
           ]
         | Addr (r, name) ->
           (* the function's absolute byte address, as load_const builds any 32-bit
              constant: MOV' the high halfword (u: imm lands <<16), IOR the low *)
           let byte = code_base + (4 * sym name) in
           [ R.Alu
               { op = R.Mov
               ; u = true
               ; v = false
               ; a = r
               ; b = 0
               ; operand = R.Imm ((byte lsr 16) land 0xFFFF)
               }
           ; R.Alu
               { op = R.Ior
               ; u = false
               ; v = false
               ; a = r
               ; b = r
               ; operand = R.Imm (byte land 0xFFFF)
               }
           ])
      o.frags
  in
  { code = List.concat_map resolve_obj objs; symbols; code_base }
;;
