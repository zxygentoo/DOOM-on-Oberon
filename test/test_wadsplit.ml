(* Wad.split invariants (AGENT.md §3): reassembly identity, chunk size bounds,
   the boundary shapes (remainder, exact multiple, sub-chunk, single), and the
   PO filesystem constants the defaults ride inside. *)

open Doomcc_core

let failures = ref 0
let total = ref 0

let check name cond =
  incr total;
  if not cond
  then (
    incr failures;
    Printf.printf "FAIL: %s\n" name)
;;

let eqi name got want =
  incr total;
  if got <> want
  then (
    incr failures;
    Printf.printf "FAIL: %s: got %d, want %d\n" name got want)
;;

(* Deterministic non-repeating filler: a wrong offset or order can't alias. *)
let data n = Bytes.init n (fun i -> Char.chr (((i * 31) + (i lsr 8)) land 0xFF))
let reassemble chunks = Bytes.concat Bytes.empty chunks

let () =
  List.iter
    (fun (name, len, cs) ->
       let d = data len in
       let chunks = Wad.split ~chunk_size:cs d in
       check (name ^ "_identity") (Bytes.equal (reassemble chunks) d);
       eqi (name ^ "_count") (List.length chunks) ((len + cs - 1) / cs);
       check
         (name ^ "_bounds")
         (List.for_all (fun c -> Bytes.length c > 0 && Bytes.length c <= cs) chunks);
       (* every chunk but the last is exactly full *)
       let rec full = function
         | [] | [ _ ] -> true
         | c :: rest -> Bytes.length c = cs && full rest
       in
       check (name ^ "_full_prefix") (full chunks))
    [ "remainder", 10_000, 4096
    ; "exact_multiple", 8192, 4096
    ; "sub_chunk", 100, 4096
    ; "single_exact", 4096, 4096
    ];
  check "empty_input" (Wad.split ~chunk_size:4096 Bytes.empty = []);
  check
    "chunk_size_zero_rejected"
    (match Wad.split ~chunk_size:0 (data 4) with
     | exception Invalid_argument _ -> true
     | _ -> false);
  (* The PO file cap: FileDir.Mod's 64 direct + 12x256 indirect 1 KB sectors
     minus the 352-byte header — and the default chunk sits inside it. *)
  eqi "po_file_cap" Wad.po_file_cap 3_210_912;
  check "default_inside_cap" (Wad.default_chunk_size <= Wad.po_file_cap);
  (* The real payload: shareware DOOM1.WAD splits into exactly two chunks whose
     Oberon-side names fit the FS's 31-char limit. *)
  let doom1 = 4_196_020 in
  eqi "doom1_chunks" ((doom1 + Wad.default_chunk_size - 1) / Wad.default_chunk_size) 2;
  check "doom1_names" (String.length (Wad.chunk_name "doom1.wad" 1) <= 31);
  if !failures = 0
  then Printf.printf "wadsplit: ok, %d checks passed\n" !total
  else (
    Printf.printf "wadsplit: FAILED %d/%d checks\n" !failures !total;
    exit 1)
;;
