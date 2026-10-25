(** WAD chunking for the stub loader: the Project Oberon filesystem caps a single file
    below DOOM1.WAD's ~4 MB, so the WAD travels the stock FS as plain byte-range chunk
    files (not valid WADs) that the stub concatenates into himem. The chunks carry no
    framing — the name sequence is the manifest: the stub loads [name.0], [name.1],
    ... until a name is missing (at most {!max_chunks} of them). *)

(** Max data bytes in one PO file: FileDir.Mod's 64 direct + 12×256 indirect 1 KB
    sectors, minus the 352-byte header in the first sector — 3 210 912. *)
val po_file_cap : int

(** Default chunk size, 3 MiB — inside {!po_file_cap} with ~64 KB headroom. *)
val default_chunk_size : int

(** [chunk_name base i] is ["<base>.<i>"], the name the stub derives the same way. *)
val chunk_name : string -> int -> string

(** The stub's chunk limits (patch/oberon/DOOM.Mod's load loop). Its names carry
    one decimal digit, so it loads at most [max_chunks] = 10 chunks ([.0] .. [.9])
    and silently stops there. And it stores whole words at [WadBase + bytes so
    far]: a RISC5 word store ignores the address's low two bits, so a chunk
    boundary that isn't word-aligned would overwrite the previous chunk's tail. *)
val max_chunks : int

(** [check_chunk_size ~len chunk_size] is [Ok ()] when splitting [len] bytes into
    [chunk_size]-byte chunks gives files the stub loads back intact: [chunk_size]
    positive, a multiple of 4, at most {!po_file_cap}, and at most {!max_chunks}
    chunks. [Error why] otherwise. *)
val check_chunk_size : len:int -> int -> (unit, string) result

(** Split into chunks of [chunk_size] bytes, the last one the remainder (never
    empty); empty input yields no chunks. Raises [Invalid_argument] on a
    non-positive [chunk_size]. *)
val split : chunk_size:int -> bytes -> bytes list
