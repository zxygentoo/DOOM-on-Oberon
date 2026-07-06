(* Globals (static-storage) placement, DB-relative (ABI §2/§6) — the embryo of the 3b
   linker's data/bss layout. Walk a file's global *definitions* (GVar; CIL folds
   statics into globals), give each a DB-relative byte offset at natural alignment,
   and serialize initializers little-endian into one zero-filled image. Data and bss
   arrive fused: the jig zero-fills the whole image exactly as the stub zeroes .bss —
   same contract, small scale; the real 3b linker splits bss out only to keep the
   blob *file* short.

   Deliberately *tolerant*: a global the current slice can't place (union, float ban,
   link-time-address initializer) is recorded in [skipped] with its reason instead of
   raised — so Fundec attributes the refusal to the functions that actually touch it,
   and every other function keeps compiling (the doomcc-histogram semantics). Places any
   type whose scalar leaves are integers or pointers (arrays/structs included, all widths
   through s3.3); unions and link-time initializers wait for later slices. *)

module C = GoblintCil

type t =
  { offsets : (int, int) Hashtbl.t (* varinfo.vid -> DB-relative byte offset *)
  ; skipped : (int, string) Hashtbl.t (* vid -> why it has no offset (refusal message) *)
  ; strings :
      (string, int) Hashtbl.t (* string-literal content -> DB-relative byte offset *)
  ; relocs : (int * int) list
    (* pointer-valued initializer slots: (image byte offset, DB-relative target). The
       image holds 0 there; the consumer writes DB + target once DB is fixed — the jig
       at its data base, the 3b linker at the blob's (ABI §6 absolute pointer words) *)
  ; image : bytes (* data+bss, little-endian, length padded to a word multiple *)
  }

let no_globals =
  { offsets = Hashtbl.create 1
  ; skipped = Hashtbl.create 1
  ; strings = Hashtbl.create 1
  ; relocs = []
  ; image = Bytes.empty
  }
;;

(* Mem-op offsets are 20-bit signed (ABI §1): DB reaches +512 KB — the whole image
   must sit inside (DOOM's data 62 K + bss 245 K ≈ 307 K does, spike-measured). *)
let max_db_offset = 0x7FFFF

(* An initializer we can serialize as a plain value today: a compile-time integer
   constant reached through any stack of pointer/integer casts — NULL macro-expands to
   a typed pointer cast wrapped around the void-pointer cast of 0, a cast OF a cast,
   which a one-level peek missed (the census found it under most of the tree's = NULL
   inits) — or a constant *double* expression under a
   cast to an integer type: DOOM's automap arrow tables are (fixed_t)(.867 * 65536)-shaped,
   folded here at compile time with C's truncate-toward-zero cast (OCaml's int_of_float),
   so no float ever reaches the blob. Address-shaped initializers are the caller's job
   (ptr_target / relocs below); what neither takes — function pointers, &extern — waits
   for the 3b linker's code addresses. *)
let rec int_core (e : C.exp) : int option =
  match C.getInteger e with
  | Some n -> Some (C.Cilint.int_of_cilint n)
  | None ->
    (match e with
     | C.CastE (_, t, e') when C.isPointerType t || C.isIntegralType t ->
       (match int_core e' with
        | Some _ as n -> n
        | None ->
          if C.isIntegralType t then Option.map int_of_float (float_const e') else None)
     | _ -> None)

(* the double-expression evaluator behind the fixed-point fold; mirrors what gcc's own
   compile-time folding computes, so the jig's oracle agrees bit-for-bit *)
and float_const (e : C.exp) : float option =
  match e with
  | C.Const (C.CReal (f, _, _)) -> Some f
  | C.UnOp (C.Neg, e', _) -> Option.map Float.neg (float_const e')
  | C.CastE (_, t, e')
    when match C.unrollType t with
         | C.TFloat _ -> true
         | _ -> false ->
    (match float_const e' with
     | Some _ as f -> f
     | None -> Option.map float_of_int (int_core e') (* (double)65536 *))
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

let word_of_init (e : C.exp) : int =
  match int_core (C.constFold true e) with
  | Some n -> n
  | None -> Check.unsupported "global initializer needs a link-time address — 3b linker"
;;

(* A pointer-valued initializer whose target is *data*: a string literal (interned at a
   known offset by the scan below) or &global / global-array decay, any constant
   Field/Index chain folded in via bitsOffset. The image cannot hold the absolute
   address — DB isn't fixed until load — so the slot is recorded as a reloc,
   (image byte offset, DB-relative target), and the image's consumer patches it to
   DB + target: the jig at its data_base, the 3b linker at the blob's (the "pointer-valued
   data initializers as absolute words" of ABI §6). Function pointers fall through to
   None: code addresses don't exist until the linker lays the code out. *)
let ptr_target ~offsets ~strings (e : C.exp) : int option =
  let rec strip e =
    match e with
    | C.CastE (_, t, e') when C.isPointerType t -> strip e'
    | e -> e
  in
  match strip e with
  | C.Const (C.CStr (s, _)) -> Hashtbl.find_opt strings s
  | (C.AddrOf (C.Var g, off) | C.StartOf (C.Var g, off)) when g.vglob ->
    (match Hashtbl.find_opt offsets g.vid with
     | None -> None (* the host global is skipped or extern; the refusal names it *)
     | Some base ->
       (try Some (base + (fst (C.bitsOffset g.vtype off) / 8)) with
        | C.SizeOfError _ -> None))
  | _ -> None
;;

(* A type places iff every leaf is an integer scalar (word / short / char) or pointer —
   arrays and structs included (natural alignment ≤ 4, ABI §4, so layout can't diverge
   from gcc -m32; the spike verified identical struct metrics under our machdep). The
   64-bit ban and float ban are enforced upstream by {!Check.check_unsupported_types},
   so every width reaching here (8/16/32) now serializes; only unions are left out. *)
let rec check_placeable (t : C.typ) =
  match C.unrollType t with
  | C.TInt _ | C.TEnum _ | C.TPtr _ -> ()
  | C.TArray (elem, _, _) -> check_placeable elem
  | C.TComp (ci, _) when ci.cstruct ->
    List.iter (fun (f : C.fieldinfo) -> check_placeable f.ftype) ci.cfields
  | C.TComp _ -> Check.unsupported "union global — later slice"
  | _ -> Check.unsupported "global of unsupported type — later slice"
;;

(* Serialize [init] (whose slot has type [t]) at byte [off] into the writes list as
   (offset, value, byte-width) triples — the width comes from the *slot* type, not the
   initializer expression (a char slot with an int-literal init is still one byte) —
   or, for an address-shaped leaf, into the relocs list (a pointer slot is always a
   4-byte word). CompoundInit offsets are single-level (Field/Index with NoOffset —
   CIL's documented shape); nested aggregates recurse; absent entries stay zero because
   the image is pre-zeroed — C's partial-initializer semantics for free. *)
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
           | C.Field (fi, C.NoOffset) -> fst (C.bitsOffset ct o) / 8, fi.ftype
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
  (* Pass 1 — placement only: assign every global its offset, defer initializer
     serialization to pass 3. Split because an initializer may reference the address of
     a global defined *later* (int *p = &x; ... int x;) or a string literal (interned in
     pass 2) — serialization needs the finished offset and string tables. *)
  let place (v : C.varinfo) (init : C.init option) =
    Check.check_unsupported_types v.vtype;
    check_placeable v.vtype;
    let size = C.bitsSizeOf v.vtype / 8
    and align = C.alignOf_int v.vtype in
    let off = (!cursor + align - 1) / align * align in
    if off + size > max_db_offset
    then Check.unsupported "data+bss image exceeds DB's +512 KB mem-op reach";
    (match init with
     | None -> () (* tentative definition: bss-style, stays zero *)
     | Some i -> pending := (v, off, i) :: !pending);
    Hashtbl.replace offsets v.vid off;
    cursor := off + size
  in
  C.iterGlobals file (fun g ->
    match g with
    | C.GVar (v, ii, _) ->
      (try place v ii.init with
       | Check.Unsupported why -> Hashtbl.replace skipped v.vid why
       | C.SizeOfError (why, _) ->
         Hashtbl.replace skipped v.vid ("global with incomplete type (" ^ why ^ ")"))
    | _ -> () (* GVarDecl w/o GVar = true extern: no offset; Fundec names it on use *));
  (* String literals are anonymous static data: scan every expression (function bodies *and*
     global initializers) for a CStr and append its bytes — the content plus a NUL — after the
     placed globals, deduplicating identical literals. Fundec then materializes each as
     DB + offset, the same address form a global gets; the NUL rides free (image is pre-zeroed). *)
  let intern (s : string) =
    if not (Hashtbl.mem strings s)
    then (
      let len = String.length s + 1 in
      if !cursor + len <= max_db_offset
      then (
        Hashtbl.replace strings s !cursor;
        string_blits := (!cursor, s) :: !string_blits;
        cursor := !cursor + len
        (* past DB's +512 KB reach: leave uninterned — Fundec refuses functions that use it *)))
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
  (* Pass 3 — serialize, to a FIXED POINT. A global can place (pass 1) yet fail here (a
     function-pointer table, say): it must be un-placed and skipped. But another global's
     initializer may hold its address — and if that reloc resolved before the failure, it
     would silently point at a zeroed gap (a miscompile, not a refusal). Dry-run rounds
     catch the cascade: each failure removes the vid from [offsets], so a referrer's
     ptr_target misses on the next round and the referrer fails too — honestly, by
     refusal. Then the survivors serialize for real. *)
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
  (* blit each interned string's content; its trailing NUL is already zero in the image *)
  List.iter
    (fun (off, s) -> Bytes.blit_string s 0 image off (String.length s))
    !string_blits;
  { offsets; skipped; strings; relocs = !relocs; image }
;;
