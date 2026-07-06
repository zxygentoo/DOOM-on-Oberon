(* The pre-codegen checks (ABI §4 + the spikes/cil census), shared by Globals and
   Fundec: [Unsupported] is the single refusal channel — raise instead of miscompiling.
   Each message names the ABI rule violated or the slice that will handle the construct;
   doomcc histograms these messages into the slice worklist. *)

module C = GoblintCil

exception Unsupported of string

let unsupported fmt = Printf.ksprintf (fun s -> raise (Unsupported s)) fmt

(* Reject the ABI §4 banned types (float / 64-bit / bitfield) wherever a type enters
   the pipeline: function signatures, locals, globals. *)
let rec check_unsupported_types (t : C.typ) =
  match t with
  | C.TInt ((C.ILongLong | C.IULongLong), _) ->
    unsupported "64-bit integer (ABI §4: no long long in the blob)"
  | C.TFloat _ -> unsupported "float (ABI §4: banned in blob v1)"
  | C.TNamed (ti, _) -> check_unsupported_types ti.ttype
  | C.TComp (ci, _) ->
    List.iter
      (fun (f : C.fieldinfo) ->
         if f.fbitfield <> None then unsupported "bitfield (ABI §4: banned)";
         check_unsupported_types f.ftype)
      ci.cfields
  | C.TArray (t', _, _) -> check_unsupported_types t'
  | _ -> ()
;;
