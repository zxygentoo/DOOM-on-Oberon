(* Globals (static-storage) placement, DB-relative (ABI §2/§6) — the embryo of the 3b
   linker's data/bss layout. Walk a file's global *definitions* (GVar; CIL folds
   statics into globals), give each a DB-relative byte offset at natural alignment,
   and serialize initializers little-endian into one zero-filled image. Data and bss
   arrive fused: the jig zero-fills the whole image exactly as the stub zeroes .bss —
   same contract, small scale; the real 3b linker splits bss out only to keep the
   blob *file* short.

   Deliberately *tolerant*: a global the current slice can't place (sub-word, union,
   float ban, link-time-address initializer) is recorded in [skipped] with its reason
   instead of raised — so Fundec attributes the refusal to the functions that
   actually touch it, and every other function keeps compiling (the doomcc-histogram
   semantics). Slice 3.2 places any type whose leaves are all 32-bit scalars
   (arrays/structs included); char/short leaves are s3.3. *)

module C = GoblintCil

type t =
  { offsets : (int, int) Hashtbl.t (* varinfo.vid -> DB-relative byte offset *)
  ; skipped : (int, string) Hashtbl.t (* vid -> why it has no offset (refusal message) *)
  ; image : bytes (* data+bss, little-endian, length padded to a word multiple *)
  }

let no_globals =
  { offsets = Hashtbl.create 1; skipped = Hashtbl.create 1; image = Bytes.empty }
;;

(* Mem-op offsets are 20-bit signed (ABI §1): DB reaches +512 KB — the whole image
   must sit inside (DOOM's data 62 K + bss 245 K ≈ 307 K does, spike-measured). *)
let max_db_offset = 0x7FFFF

(* An initializer we can serialize today: a compile-time integer constant — including
   enum constants (CEnum) and integer-constant pointer casts (NULL), which getInteger's
   CInt-and-friends coverage plus the explicit CastE case pick up. Anything needing a
   link-time address (&global, string literal, function pointer) is the 3b linker's job. *)
let word_of_init (e : C.exp) : int =
  let as_int e' = Option.map C.Cilint.int_of_cilint (C.getInteger e') in
  let folded = C.constFold true e in
  let value =
    match as_int folded with
    | Some _ as n -> n
    | None ->
      (match folded with
       | C.CastE (_, t, e') when C.isPointerType t -> as_int e' (* NULL and kin *)
       | _ -> None)
  in
  match value with
  | Some n -> n
  | None -> Check.unsupported "global initializer needs a link-time address — 3b linker"
;;

(* A type places iff every leaf is a 32-bit scalar — arrays and structs of words
   included (natural alignment ≤ 4, ABI §4, so layout can't diverge from gcc -m32;
   the spike verified identical struct metrics under our machdep). *)
let rec check_placeable (t : C.typ) =
  match C.unrollType t with
  | (C.TInt _ | C.TEnum _ | C.TPtr _) as t' ->
    if C.bitsSizeOf t' <> 32
    then Check.unsupported "sub-word global (char/short) — memory slice s3.3"
  | C.TArray (elem, _, _) -> check_placeable elem
  | C.TComp (ci, _) when ci.cstruct ->
    List.iter (fun (f : C.fieldinfo) -> check_placeable f.ftype) ci.cfields
  | C.TComp _ -> Check.unsupported "union global — later slice"
  | _ -> Check.unsupported "global of unsupported type — later slice"
;;

(* Serialize [init] at byte [off] into the writes list. CompoundInit offsets are
   single-level (Field/Index with NoOffset — CIL's documented shape); nested
   aggregates recurse; absent entries stay zero because the image is pre-zeroed —
   C's partial-initializer semantics for free. *)
let rec serialize_init writes (off : int) (init : C.init) =
  match init with
  | C.SingleInit e -> writes := (off, word_of_init e) :: !writes
  | C.CompoundInit (ct, initl) ->
    List.iter
      (fun ((o, sub) : C.offset * C.init) ->
         let delta =
           match o with
           | C.Field (_, C.NoOffset) -> fst (C.bitsOffset ct o) / 8
           | C.Index (e, C.NoOffset) ->
             (match C.getInteger (C.constFold true e), C.unrollType ct with
              | Some i, C.TArray (elem, _, _) ->
                C.Cilint.int_of_cilint i * (C.bitsSizeOf elem / 8)
              | _ -> Check.unsupported "initializer index — unexpected CIL shape")
           | _ -> Check.unsupported "initializer offset — unexpected CIL shape"
         in
         serialize_init writes (off + delta) sub)
      initl
;;

let from_file (file : C.file) : t =
  let offsets = Hashtbl.create 64
  and skipped = Hashtbl.create 64 in
  let cursor = ref 0
  and writes = ref [] in
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
     | Some i -> serialize_init writes off i);
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
  let image = Bytes.make ((!cursor + 3) / 4 * 4) '\000' in
  List.iter (fun (off, w) -> Bytes.set_int32_le image off (Int32.of_int w)) !writes;
  { offsets; skipped; image }
;;
