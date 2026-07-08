(** WAD chunking for the stub loader (AGENT.md §3): the Project Oberon filesystem
    caps a single file below DOOM1.WAD's ~4 MB, so the WAD travels the stock FS as
    plain byte-range chunk files (not valid WADs) that the stub concatenates into
    himem at init — the blob never sees storage (§2.7). Host-side tooling; the
    chunks carry no framing of their own — the name sequence is the manifest: the
    stub loads [name.0], [name.1], ... until a name is missing. *)

(** Max data bytes in one PO file: FileDir.Mod's 64 direct + 12×256 indirect 1 KB
    sectors, minus the 352-byte header in the first sector — 3 210 912. *)
val po_file_cap : int

(** Default chunk size, 3 MiB — inside {!po_file_cap} with ~64 KB headroom. *)
val default_chunk_size : int

(** [chunk_name base i] is ["<base>.<i>"], the name the stub derives the same way. *)
val chunk_name : string -> int -> string

(** Split into chunks of [chunk_size] bytes, the last one the remainder (never
    empty); empty input yields no chunks. Raises [Invalid_argument] on a
    non-positive [chunk_size]. *)
val split : chunk_size:int -> bytes -> bytes list
