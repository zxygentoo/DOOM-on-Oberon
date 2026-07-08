(* wadsplit — the host-side WAD chunk splitter (AGENT.md §3; 2c's tooling half).

   The PO filesystem caps a single file at Wad.po_file_cap (~3.06 MB); DOOM1.WAD is
   ~4 MB. Split it into plain byte-range chunk files the stock FS can hold; the stub
   concatenates them into himem at init and hands the blob one WAD pointer (§2.7 —
   the blob never touches storage).

   Usage:  wadsplit <file> [chunk_size_bytes]
   Writes <file>.0, <file>.1, ... next to the input, re-reads them, and verifies the
   concatenation is byte-identical to the input. Chunk names are Oberon filenames on
   the target — checked against the FS limits here, where failing is cheap. *)

open Doomcc_core

(* FileDir.FnLength = 32 including the terminating 0X. *)
let po_name_max = 31
let read_file path = In_channel.with_open_bin path In_channel.input_all

let write_file path s =
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc s)
;;

let fail fmt =
  Printf.ksprintf
    (fun s ->
       prerr_endline s;
       exit 1)
    fmt
;;

let () =
  let input, chunk_size =
    match Array.to_list Sys.argv with
    | [ _; input ] -> input, Wad.default_chunk_size
    | [ _; input; size ] ->
      (match int_of_string_opt size with
       | Some n -> input, n
       | None -> fail "wadsplit: chunk size must be an integer: %s" size)
    | _ -> fail "usage: wadsplit <file> [chunk_size_bytes]"
  in
  if chunk_size > Wad.po_file_cap
  then
    fail "wadsplit: chunk size %d exceeds the PO file cap %d" chunk_size Wad.po_file_cap;
  let data = read_file input in
  if String.length data = 0 then fail "wadsplit: %s is empty" input;
  let chunks = Wad.split ~chunk_size (Bytes.of_string data) in
  let names = List.mapi (fun i _ -> Wad.chunk_name input i) chunks in
  List.iter
    (fun name ->
       let oberon_name = Filename.basename name in
       if String.length oberon_name > po_name_max
       then
         fail
           "wadsplit: %S is %d chars; PO filenames cap at %d"
           oberon_name
           (String.length oberon_name)
           po_name_max)
    names;
  List.iter2 (fun name c -> write_file name (Bytes.to_string c)) names chunks;
  (* Verify from the files themselves: what the stub will read, not what we meant. *)
  let reread = String.concat "" (List.map read_file names) in
  if not (String.equal reread data)
  then fail "wadsplit: chunk verification FAILED — reassembly differs from %s" input;
  List.iter2
    (fun name c ->
       Printf.printf
         "  %-24s %9d bytes  (Oberon: %s)\n"
         name
         (Bytes.length c)
         (Filename.basename name))
    names
    chunks;
  Printf.printf
    "wadsplit: %s -> %d chunks, %d bytes, reassembly verified\n"
    input
    (List.length chunks)
    (String.length data)
;;
