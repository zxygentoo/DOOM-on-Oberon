(* The pre-codegen checks (ABI §4 + the cil-spike.md census), shared by Globals and
   Fundec: [Unsupported] is the single refusal channel — raise instead of miscompiling.
   Each message names the ABI rule violated or the slice that will handle the construct;
   doomcc histograms these messages into the slice worklist. *)

module C = GoblintCil

exception Unsupported of string

let unsupported fmt = Printf.ksprintf (fun s -> raise (Unsupported s)) fmt

(* A byte-aligned :8 bitfield is degenerate — GCC's little-endian ABI allocates
   bitfields LSB-first within the storage unit, so an 8-bit field at bit offset 8k
   IS byte k of the struct: one addressable byte, served by LDB/STB (the s3.3
   machinery) with no read-modify-write. DOOM's only live bitfields have exactly
   this shape (struct color's b/g/r/a — the dither-LUT feed). Anything else —
   other widths, or an :8 pushed off-byte by a preceding field — stays banned. *)
let byte_bitfield (fi : C.fieldinfo) =
  fi.fbitfield = Some 8
  && fst (C.bitsOffset (C.TComp (fi.fcomp, [])) (C.Field (fi, C.NoOffset))) mod 8 = 0
;;

(* Reject the ABI §4 banned types (float / 64-bit / non-degenerate bitfield)
   wherever a type enters the pipeline: function signatures, locals, globals. *)
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
