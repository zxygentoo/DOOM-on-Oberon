(* WAD chunking for the stub loader (AGENT.md §3). See wad.mli. *)

(* FileDir.Mod: SecTabSize=64 direct + ExTabSize=12 × IndexSize=256 indirect
   1 KB sectors; HeaderSize=352 lives in the first data sector. *)
let po_file_cap = (64 * 1024) - 352 + (12 * 256 * 1024)
let default_chunk_size = 3 * 1024 * 1024
let chunk_name base i = Printf.sprintf "%s.%d" base i

(* DOOM.Mod: WHILE (i <= 9) & (len >= 0) — one decimal digit per chunk name *)
let max_chunks = 10

let check_chunk_size ~len chunk_size =
  let err fmt = Printf.ksprintf (fun s -> Error s) fmt in
  if chunk_size <= 0
  then err "chunk size %d must be positive" chunk_size
  else if chunk_size land 3 <> 0
  then err "chunk size %d is not a multiple of 4 (the stub stores whole words)" chunk_size
  else if chunk_size > po_file_cap
  then err "chunk size %d exceeds the PO file cap %d" chunk_size po_file_cap
  else (
    let n = (len + chunk_size - 1) / chunk_size in
    if n > max_chunks
    then
      err
        "%d bytes in %d-byte chunks is %d chunks; the stub loads at most %d"
        len
        chunk_size
        n
        max_chunks
    else Ok ())
;;

let split ~chunk_size data =
  if chunk_size <= 0 then invalid_arg "Wad.split: chunk_size must be positive";
  let len = Bytes.length data in
  let rec go off acc =
    if off >= len
    then List.rev acc
    else (
      let n = min chunk_size (len - off) in
      go (off + n) (Bytes.sub data off n :: acc))
  in
  go 0 []
;;
