(** The blob envelope (ABI §7, §8): section layout at a base address, the 64-byte
    header, the additive checksum, and the file bytes the stub loads into himem.

    Sections, in file order: header (64 B) · code · data. The bss is reserved, not
    emitted — the header carries its absolute start and length and the stub zeroes the
    range. DB points at [data_base]; the image links at [base] with no relocation. *)

type layout =
  { base : int (** BLOB_BASE: where the header lands *)
  ; code_base : int (** base + 64 — what {!Linker.link} takes *)
  ; data_base : int (** code end, word-aligned — DB (R13) points here *)
  ; bss_base : int (** data end — the stub zeroes [bss_base, bss_base+bss_length) *)
  ; bss_length : int
  ; image_length : int (** header + code + data, bytes — the file's length *)
  }

(** Compute the section layout. [data_size]/[bss_size] come from {!Globals.t}
    ([data_size] and [image length − data_size]); both are word multiples. *)
val layout : base:int -> code_words:int -> data_size:int -> bss_size:int -> layout

(** Render the blob file: header (magic, version, lengths, entry offsets, checksum —
    additive u32 over the image words after the header) + encoded code + data.
    [entries] are the Init/Tick/KeyIn offsets from [base] (0 = absent). [data] must be
    exactly the data section ([Globals.data_size] bytes, relocs already patched). *)
val emit
  :  layout:layout
  -> code:Emu.Risc5_isa.instr list
  -> data:bytes
  -> entries:int * int * int
  -> bytes
