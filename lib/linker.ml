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

type obj =
  { name : string
  ; frags : frag list
  }

type image =
  { code : R.instr list
  ; symbols : (string * int) list
  }

let frag_width = function
  | Label _ -> 0
  | Ins _ | Bcc _ | Jmp _ | Call _ -> 1
;;

let code_size o = List.fold_left (fun a f -> a + frag_width f) 0 o.frags

let link (objs : obj list) : image =
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
    List.filter_map
      (fun f ->
         let here = !a in
         let branch cond neg target =
           R.Branch { cond; neg; link = false; target = R.To_off (target - here - 1) }
         in
         match f with
         | Label _ -> None
         | Ins i ->
           incr a;
           Some i
         | Bcc (cond, neg, l) ->
           incr a;
           Some (branch cond neg (Hashtbl.find addr l))
         | Jmp l ->
           incr a;
           Some (branch R.True false (Hashtbl.find addr l))
         | Call name ->
           incr a;
           Some
             (R.Branch
                { cond = R.True
                ; neg = false
                ; link = true
                ; target = R.To_off (sym name - here - 1)
                }))
      o.frags
  in
  { code = List.concat_map resolve_obj objs; symbols }
;;
