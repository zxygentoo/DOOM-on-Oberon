(* WAD chunking for the stub loader (AGENT.md §3). See wad.mli. *)

(* FileDir.Mod: SecTabSize=64 direct + ExTabSize=12 × IndexSize=256 indirect
   1 KB sectors; HeaderSize=352 lives in the first data sector. *)
let po_file_cap = (64 * 1024) - 352 + (12 * 256 * 1024)
let default_chunk_size = 3 * 1024 * 1024
let chunk_name base i = Printf.sprintf "%s.%d" base i

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
