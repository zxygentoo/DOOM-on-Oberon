(** The crt0 entry thunks (ABI §7): the blob-side half of the boundary protocol. The
    stub BLs a header entry offset; the thunk parks Oberon's R6-R15 (MT/SB/SP/LNK
    included) in a save area, installs the C world (SP = stack_top − 16 for the home
    area, DB = the blob's data base), BLs the C entry with the args untouched in R0/R1,
    restores all ten, and returns to the stub with the C result in R0.

    One save area serves every thunk: with interrupts unused, exactly one is active at
    a time. Storing R6-R15 needs a base register that isn't Oberon's: R0-R5 are outside
    the save contract and R0/R1 carry the args, so R5 holds the save-area address
    (reloaded after the C entry, which clobbers it). Every baked-in constant loads in
    the fixed 2-word form, so a thunk's size never depends on values that exist only
    after layout. *)

(** [thunk ~name ~entry ~save_area ~stack_top ~data_base] — the [Linker.obj] for one
    entry: [name] is the thunk's own symbol (what the header points at), [entry] the C
    function it wraps, the rest the link-time constants. Fixed size: {!size} words. *)
val thunk
  :  name:string
  -> entry:string
  -> save_area:int
  -> stack_top:int
  -> data_base:int
  -> Linker.obj

(** Words one thunk occupies — needed to size the code section before the layout (and
    so the constants) exist. *)
val size : int

(** Bytes of save area a blob needs (10 words: R6-R15) — the caller adds this to the
    bss it asks {!Blob.layout} for, placing the area in stub-zeroed blob memory. *)
val save_area_size : int
