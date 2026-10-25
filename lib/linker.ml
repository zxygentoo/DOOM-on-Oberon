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
  ; sym_tbl : (string, int) Hashtbl.t
  ; code_base : int
  }

(* name -> expansion, so an intrinsic's width (frag_width) and its emitted code are
   one list and can't disagree *)
let intrinsics : (string * R.instr list) list =
  [ ( "FixedMul"
    , (* (int64 a * int64 b) >> 16 with no 64-bit value: MUL leaves the low
         word in R0 and the high in H; the result is the middle 32 bits,
         high<<16 | low>>>16. ROR+AND is the logical >>16 — RISC5 has no LSR *)
      [ R.Alu { op = R.Mul; u = false; v = false; a = 0; b = 0; operand = R.Reg 1 }
      ; R.Alu { op = R.Mov; u = true; v = false; a = 1; b = 0; operand = R.Reg 0 }
      ; R.Alu { op = R.Lsl; u = false; v = false; a = 1; b = 1; operand = R.Imm 16 }
      ; R.Alu { op = R.Ror; u = false; v = false; a = 0; b = 0; operand = R.Imm 16 }
      ; R.Alu { op = R.And; u = false; v = false; a = 0; b = 0; operand = R.Imm 0xFFFF }
      ; R.Alu { op = R.Ior; u = false; v = false; a = 0; b = 1; operand = R.Reg 0 }
      ] )
  ]
;;

let is_intrinsic name = List.mem_assoc name intrinsics

let frag_width = function
  | Label _ -> 0
  | Ins _ | Bcc _ | Jmp _ -> 1
  | Call name ->
    (match List.assoc_opt name intrinsics with
     | Some expansion -> List.length expansion
     | None -> 1)
  | Addr _ -> 2
;;

let code_size o = List.fold_left (fun a f -> a + frag_width f) 0 o.frags

(* u: MOV's 16-bit immediate lands in the high halfword *)
let load_const_pair d n =
  [ R.Alu
      { op = R.Mov
      ; u = true
      ; v = false
      ; a = d
      ; b = 0
      ; operand = R.Imm ((n lsr 16) land 0xFFFF)
      }
  ; R.Alu
      { op = R.Ior; u = false; v = false; a = d; b = d; operand = R.Imm (n land 0xFFFF) }
  ]
;;

let referenced_syms (o : obj) : string list =
  List.filter_map
    (function
      | Call n | Addr (_, n) -> Some n
      | Ins _ | Label _ | Bcc _ | Jmp _ -> None)
    o.frags
;;

let find_sym_addr (img : image) name =
  Option.map (fun off -> img.code_base + (4 * off)) (Hashtbl.find_opt img.sym_tbl name)
;;

let sym_addr (img : image) name =
  match find_sym_addr img name with
  | Some addr -> addr
  | None -> Check.unsupported "address of undefined function %s" name
;;

let link ~(code_base : int) (objs : obj list) : image =
  (* pass 1: each function's base word offset *)
  let sym_tbl = Hashtbl.create 1024 in
  let _, rev_syms =
    List.fold_left
      (fun (off, syms) o ->
         if Hashtbl.mem sym_tbl o.name
         then invalid_arg ("Linker.link: duplicate symbol " ^ o.name);
         Hashtbl.add sym_tbl o.name off;
         off + code_size o, (o.name, off) :: syms)
      (0, [])
      objs
  in
  let symbols = List.rev rev_syms in
  let sym name =
    match Hashtbl.find_opt sym_tbl name with
    | Some off -> off
    | None -> Check.unsupported "call to undefined function %s" name
  in
  (* pass 2: resolve each function at its base *)
  let resolve_obj o =
    let base = Hashtbl.find sym_tbl o.name in
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
         (* a PC-relative branch at word A lands at A + 1 + off *)
         let branch cond neg target =
           R.Branch { cond; neg; link = false; target = R.To_off (target - here - 1) }
         in
         match f with
         | Label _ -> []
         | Ins i -> [ i ]
         | Bcc (cond, neg, l) -> [ branch cond neg (Hashtbl.find addr l) ]
         | Jmp l -> [ branch R.True false (Hashtbl.find addr l) ]
         | Call name ->
           (match List.assoc_opt name intrinsics with
            | Some expansion -> expansion
            | None ->
              [ R.Branch
                  { cond = R.True
                  ; neg = false
                  ; link = true
                  ; target = R.To_off (sym name - here - 1)
                  }
              ])
         | Addr (r, name) -> load_const_pair r (code_base + (4 * sym name)))
      o.frags
  in
  { code = List.concat_map resolve_obj objs; symbols; sym_tbl; code_base }
;;
