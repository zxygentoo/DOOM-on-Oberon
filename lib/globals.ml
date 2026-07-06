(* Globals (static-storage) placement, DB-relative (ABI §2/§6) — the embryo of the 3b
   linker's data/bss layout. Walk a file's global *definitions* (GVar; CIL folds
   statics into globals), give each a DB-relative byte offset at natural alignment,
   and serialize initializers little-endian into one zero-filled image. Data and bss
   arrive fused: the jig zero-fills the whole image exactly as the stub zeroes .bss —
   same contract, small scale; the real 3b linker splits bss out only to keep the
   blob *file* short.

   Deliberately *tolerant*: a global the current slice can't place (aggregate,
   sub-word, float ban) is recorded in [skipped] with its reason instead of raised —
   so Fundec attributes the refusal to the functions that actually touch it, and
   every other function keeps compiling (the doomcc-histogram semantics). Slice 3.1
   places 32-bit scalars only; aggregates are s3.2, char/short globals s3.3. *)

module C = GoblintCil

type t =
  { offsets : (int, int) Hashtbl.t (* varinfo.vid -> DB-relative byte offset *)
  ; skipped : (int, string) Hashtbl.t (* vid -> why it has no offset (refusal message) *)
  ; image : bytes (* data+bss, little-endian, length padded to a word multiple *)
  }

let no_globals = { offsets = Hashtbl.create 1; skipped = Hashtbl.create 1; image = Bytes.empty }

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
  | None ->
    Check.unsupported "global initializer needs a link-time address — 3b linker"

let from_file (file : C.file) : t =
  let offsets = Hashtbl.create 64
  and skipped = Hashtbl.create 64 in
  let cursor = ref 0
  and writes = ref [] in
  let place (v : C.varinfo) (init : C.init option) =
    Check.check_unsupported_types v.vtype;
    (match C.unrollType v.vtype with
     | (C.TInt _ | C.TEnum _ | C.TPtr _) when C.bitsSizeOf v.vtype = 32 -> ()
     | C.TInt _ -> Check.unsupported "sub-word global (char/short) — memory slice s3.3"
     | C.TArray _ | C.TComp _ ->
       Check.unsupported "global aggregate (array/struct) — memory slice s3.2"
     | _ -> Check.unsupported "global of unsupported type — later slice");
    let size = C.bitsSizeOf v.vtype / 8
    and align = C.alignOf_int v.vtype in
    let off = (!cursor + align - 1) / align * align in
    if off + size > max_db_offset
    then Check.unsupported "data+bss image exceeds DB's +512 KB mem-op reach";
    (match init with
     | None -> () (* tentative definition: bss-style, stays zero *)
     | Some (C.SingleInit e) -> writes := (off, word_of_init e) :: !writes
     | Some (C.CompoundInit _) ->
       Check.unsupported "aggregate initializer — memory slice s3.2");
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
