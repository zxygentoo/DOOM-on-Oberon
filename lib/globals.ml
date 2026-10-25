module C = GoblintCil

type reloc_target =
  | Data of int
  | Code of string

type t =
  { offsets : (int, int) Hashtbl.t
  ; skipped : (int, string) Hashtbl.t
  ; strings : (string, int) Hashtbl.t
  ; relocs : (int * reloc_target) list
  ; image : bytes
  ; data_size : int
  }

(* mem-op offsets are 20-bit signed: DB reaches +512 KB, and the whole image must sit
   inside *)
let max_db_offset = 0x7FFFF

(* Recurses through cast stacks: NULL expands to a pointer cast around a cast of 0. *)
let rec int_core (e : C.exp) : int option =
  match C.getInteger e with
  | Some n -> Some (C.Cilint.int_of_cilint n)
  | None ->
    (match e with
     | C.CastE (_, t, e') when C.isPointerType t || C.isIntegralType t ->
       let v =
         match int_core e' with
         | Some _ as n -> n
         | None ->
           if C.isIntegralType t then Option.map int_of_float (float_const e') else None
       in
       (* width-exact: a narrowing cast wraps as the machine will — gen_expr folds
          these too, as values *)
       Option.map
         (fun v ->
            let bits = if C.isPointerType t then 32 else C.bitsSizeOf t in
            if bits >= 32
            then v
            else (
              let x = v land ((1 lsl bits) - 1) in
              let signed =
                match C.unrollType t with
                | C.TInt (ik, _) -> C.isSigned ik
                | _ -> false
              in
              if signed && x land (1 lsl (bits - 1)) <> 0 then x - (1 lsl bits) else x))
         v
     | _ -> None)

(* Double only: an OCaml float is a double, so a float (1.0f, (float)x) or long double
   constant would fold at the wrong precision ((int)16777217.0f is 16777216). Those
   answer None and reach the float ban. CIL's constFold leaves float-to-int casts
   alone, so this is the only folder. *)
and float_const (e : C.exp) : float option =
  match e with
  | C.Const (C.CReal (f, C.FDouble, _)) -> Some f
  | C.UnOp (C.Neg, e', _) -> Option.map Float.neg (float_const e')
  | C.CastE (_, t, e')
    when match C.unrollType t with
         | C.TFloat (C.FDouble, _) -> true
         | _ -> false ->
    (match float_const e' with
     | Some _ as f -> f
     | None -> Option.map float_of_int (int_core e'))
  | C.BinOp (op, a, b, _) ->
    (match float_const a, float_const b with
     | Some x, Some y ->
       (match op with
        | C.Mult -> Some (x *. y)
        | C.PlusA -> Some (x +. y)
        | C.MinusA -> Some (x -. y)
        | C.Div -> Some (x /. y)
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

(* [e] arrives constant-folded (serialize_init folds once, for this and ptr_target) *)
let word_of_init (e : C.exp) : int =
  (* a float value in [e]: one of the non-double constants float_const won't fold *)
  let rec mentions_float (e : C.exp) =
    (match C.unrollType (C.typeOf e) with
     | C.TFloat _ -> true
     | _ -> false)
    ||
    match e with
    | C.CastE (_, _, e') | C.UnOp (_, e', _) -> mentions_float e'
    | C.BinOp (_, a, b, _) -> mentions_float a || mentions_float b
    | _ -> false
  in
  match int_core e with
  | Some n -> n
  | None when mentions_float e -> Check.unsupported "float (ABI §4: banned in blob v1)"
  | None -> Check.unsupported "global initializer is not a compile- or link-time constant"
;;

(* The image can't hold an absolute address — neither base is fixed at compile time —
   so every pointer-valued slot becomes a reloc the consumer patches. A function's
   reloc carries its symbol; an unknown name fails at link. *)
let ptr_target ~offsets ~strings (e : C.exp) : reloc_target option =
  let rec strip e =
    match e with
    | C.CastE (_, t, e') when C.isPointerType t -> strip e'
    | e -> e
  in
  match strip e with
  | C.Const (C.CStr (s, _)) ->
    Option.map (fun off -> Data off) (Hashtbl.find_opt strings s)
  | (C.AddrOf (C.Var f, C.NoOffset) | C.StartOf (C.Var f, C.NoOffset))
    when C.isFunctionType (C.unrollType f.vtype) -> Some (Code f.vname)
  | (C.AddrOf (C.Var g, off) | C.StartOf (C.Var g, off)) when g.vglob ->
    (match Hashtbl.find_opt offsets g.vid with
     | None -> None (* the host global is skipped or extern; the refusal names it *)
     | Some base ->
       (try Some (Data (base + (fst (C.bitsOffset g.vtype off) / 8))) with
        | C.SizeOfError _ -> None))
  | _ -> None
;;

(* Integers and pointers at the leaves, through arrays, structs and unions; float and
   64-bit are refused earlier by Check. *)
let rec check_placeable (t : C.typ) =
  match C.unrollType t with
  | C.TInt _ | C.TEnum _ | C.TPtr _ -> ()
  | C.TArray (elem, _, _) -> check_placeable elem
  | C.TComp (ci, _) ->
    List.iter (fun (f : C.fieldinfo) -> check_placeable f.ftype) ci.cfields
  | _ -> Check.unsupported "global of unsupported type"
;;

(* A leaf's byte width comes from its slot type, not the initializer (a char slot with
   an int literal is one byte). Absent CompoundInit entries stay zero: the image is
   pre-zeroed. *)
let rec serialize_init ~writes ~relocs ~offsets ~strings (off : int) (t : C.typ) init =
  match init with
  | C.SingleInit e ->
    let folded = C.constFold true e in
    (match ptr_target ~offsets ~strings folded with
     | Some target -> relocs := (off, target) :: !relocs
     | None -> writes := (off, word_of_init folded, C.bitsSizeOf t / 8) :: !writes)
  | C.CompoundInit (ct, initl) ->
    List.iter
      (fun ((o, sub) : C.offset * C.init) ->
         let delta, subt =
           match o with
           | C.Field (fi, C.NoOffset) ->
             (* a byte-aligned :8 bitfield slot is one byte: its declared type
                (uint32) would write a word over the neighboring fields *)
             ( fst (C.bitsOffset ct o) / 8
             , if fi.fbitfield = None then fi.ftype else C.TInt (C.IUChar, []) )
           | C.Index (e, C.NoOffset) ->
             (match C.getInteger (C.constFold true e), C.unrollType ct with
              | Some i, C.TArray (elem, _, _) ->
                C.Cilint.int_of_cilint i * (C.bitsSizeOf elem / 8), elem
              | _ -> Check.unsupported "initializer index — unexpected CIL shape")
           | _ -> Check.unsupported "initializer offset — unexpected CIL shape"
         in
         serialize_init ~writes ~relocs ~offsets ~strings (off + delta) subt sub)
      initl
;;

let from_file (file : C.file) : t =
  let offsets = Hashtbl.create 64
  and skipped = Hashtbl.create 64
  and strings = Hashtbl.create 64 in
  let cursor = ref 0
  and writes = ref []
  and relocs = ref []
  and string_blits = ref []
  and pending = ref [] in
  (* pass 1 places, pass 3 serializes: an initializer may take the address of a global
     defined later, or of a string interned in pass 2 *)
  let place (v : C.varinfo) (init : C.init option) =
    Check.check_unsupported_types v.vtype;
    check_placeable v.vtype;
    let size = C.bitsSizeOf v.vtype / 8
    and align = C.alignOf_int v.vtype in
    let off = (!cursor + align - 1) / align * align in
    if off + size > max_db_offset
    then Check.unsupported "data+bss image exceeds DB's +512 KB mem-op reach";
    (match init with
     | None -> ()
     | Some i -> pending := (v, off, i) :: !pending);
    Hashtbl.replace offsets v.vid off;
    cursor := off + size
  in
  let gvars = ref [] in
  C.iterGlobals file (fun g ->
    match g with
    | C.GVar (v, ii, _) -> gvars := (v, ii.init) :: !gvars
    | _ -> () (* a GVarDecl alone is an extern: no offset *));
  let gvars = List.rev !gvars in
  let place_tolerant (v, init) =
    try place v init with
    | Check.Unsupported why -> Hashtbl.replace skipped v.C.vid why
    | C.SizeOfError (why, _) ->
      Hashtbl.replace skipped v.C.vid ("global with incomplete type (" ^ why ^ ")")
  in
  (* placement order is the data/bss split: initialized globals, then strings (the data
     the blob file carries), then uninitialized globals — the image's zero tail is the
     bss the stub zeroes *)
  List.iter (fun (v, init) -> if init <> None then place_tolerant (v, init)) gvars;
  (* string literals from every expression, bodies and initializers alike, deduplicated;
     each NUL is already zero in the image *)
  let intern (s : string) =
    if not (Hashtbl.mem strings s)
    then (
      let len = String.length s + 1 in
      if !cursor + len <= max_db_offset
      then (
        Hashtbl.replace strings s !cursor;
        string_blits := (!cursor, s) :: !string_blits;
        cursor := !cursor + len
        (* past DB's reach: uninterned, and Fundec refuses its users *)))
  in
  let collector =
    object
      inherit C.nopCilVisitor

      method! vexpr e =
        (match e with
         | C.Const (C.CStr (s, _)) -> intern s
         | _ -> ());
        C.DoChildren
    end
  in
  C.visitCilFileSameGlobals collector file;
  let data_size = (!cursor + 3) / 4 * 4 in
  List.iter (fun (v, init) -> if init = None then place_tolerant (v, init)) gvars;
  (* pass 3 serializes to a fixed point: a global that places but fails here (a
     function-pointer table, say) is un-placed — and a global holding its address must
     fail too, or its reloc would point at a zeroed gap. Dry runs until nothing new
     fails, then the survivors serialize for real. *)
  let skip (v : C.varinfo) why =
    Hashtbl.remove offsets v.vid;
    Hashtbl.replace skipped v.vid why
  in
  let survivors = ref (List.rev !pending)
  and changed = ref true in
  while !changed do
    changed := false;
    survivors
    := List.filter
         (fun ((v : C.varinfo), off, i) ->
            try
              let w = ref []
              and r = ref [] in
              serialize_init ~writes:w ~relocs:r ~offsets ~strings off v.vtype i;
              true
            with
            | Check.Unsupported why ->
              skip v why;
              changed := true;
              false
            | C.SizeOfError (why, _) ->
              skip v ("initializer sizing failed (" ^ why ^ ")");
              changed := true;
              false)
         !survivors
  done;
  List.iter
    (fun ((v : C.varinfo), off, i) ->
       serialize_init ~writes ~relocs ~offsets ~strings off v.vtype i)
    !survivors;
  let image = Bytes.make ((!cursor + 3) / 4 * 4) '\000' in
  List.iter
    (fun (off, w, width) ->
       match width with
       | 1 -> Bytes.set_uint8 image off (w land 0xFF)
       | 2 -> Bytes.set_uint16_le image off (w land 0xFFFF)
       | _ -> Bytes.set_int32_le image off (Int32.of_int w))
    !writes;
  List.iter
    (fun (off, s) -> Bytes.blit_string s 0 image off (String.length s))
    !string_blits;
  { offsets; skipped; strings; relocs = !relocs; image; data_size }
;;

let offset_of_name (t : t) (file : C.file) (name : string) : int option =
  List.find_map
    (function
      | C.GVar (v, _, _) when v.C.vname = name -> Hashtbl.find_opt t.offsets v.C.vid
      | _ -> None)
    file.C.globals
;;
