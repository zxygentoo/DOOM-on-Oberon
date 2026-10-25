module C = GoblintCil

exception Unsupported of string

let unsupported fmt = Printf.ksprintf (fun s -> raise (Unsupported s)) fmt

exception Internal of string

let internal fmt = Printf.ksprintf (fun s -> raise (Internal s)) fmt

let byte_bitfield (fi : C.fieldinfo) =
  fi.fbitfield = Some 8
  && fst (C.bitsOffset (C.TComp (fi.fcomp, [])) (C.Field (fi, C.NoOffset))) mod 8 = 0
;;

let rec check_unsupported_types (t : C.typ) =
  match t with
  | C.TInt ((C.ILongLong | C.IULongLong), _) ->
    unsupported "64-bit integer (ABI §4: no long long in the blob)"
  | C.TFloat _ -> unsupported "float (ABI §4: banned in blob v1)"
  | C.TNamed (ti, _) -> check_unsupported_types ti.ttype
  | C.TComp (ci, _) ->
    List.iter
      (fun (f : C.fieldinfo) ->
         if f.fbitfield <> None && not (byte_bitfield f)
         then unsupported "bitfield other than byte-aligned :8 (ABI §4)";
         check_unsupported_types f.ftype)
      ci.cfields
  | C.TArray (t', _, _) -> check_unsupported_types t'
  | _ -> ()
;;
