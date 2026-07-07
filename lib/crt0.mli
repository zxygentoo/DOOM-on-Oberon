(** The crt0 entry thunks (ABI §7): the blob-side half of the boundary protocol. The
    stub BLs a header entry offset; the thunk owns the world switch — park Oberon's
    R6-R15 (its MT/SB/SP/LNK included) in a save area, install the C world
    (SP = stack_top − 16 for the o32 home area, DB = the blob's data base), BL the C
    entry with the args untouched in R0/R1, restore all ten, and B LNK back to the
    stub with the C result in R0.

    One save area serves every thunk: cooperative single-threading means exactly one
    is active at a time (interrupts unused, AGENT.md §4). R0-R5 sit outside the save
    contract — R5 carries the save-area address (reloaded after the C entry, which
    clobbers it). All three baked-in constants load through the fixed 2-word form so
    the thunk's size never depends on their values — layout must be computable before
    the values exist. *)

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
    so the constants) exist. Checked against the real emission by an assert inside
    {!thunk}. *)
val size : int

(** Bytes of save area a blob needs (10 words: R6-R15) — the caller adds this to the
    bss it asks {!Blob.layout} for, placing the area in stub-zeroed blob memory. *)
val save_area_size : int
