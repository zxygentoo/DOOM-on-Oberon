(** The 1a hand-rolled hot-loop drawer (AGENT.md §4/1a) — perf hand code over the
    shared ISA, opened when the 1d flat profile priced a function above what compiled
    code should pay. Each drawer *replaces* the identically-named C function at link
    time (doomcc/the jig drop the compiled obj and append these), so the C source stays
    in-tree as the executable spec: the jig diffs the hand code against gcc compiling
    that very C, and the golden oracle demands pixel identity against the host build.

    First (and so far only) resident: [dither] — [__dg_dither] was 38% of every frame
    at 26 instrs/px under naive codegen; the hand loop runs ~10/px (branchless: SUB's
    unsigned borrow captures [lum > thr] in C, ADD' materializes it — no compare
    branches in the pixel path). *)

(** [dither ~lum_off ~bn_off] — the [__dg_dither] replacement. [lum_off]/[bn_off] are
    the DB-relative byte offsets of [__dg_lum] and [__dg_bn64] ({!Globals.offset_of_name}):
    hand code reaches C-side data through the same DB the compiled code uses. Clobbers
    R0-R5 and R12 (blob-internal, outside every compiled allocation pool) beyond the
    standard caller-saved set; saves/restores R6-R11 + LNK. *)
val dither : lum_off:int -> bn_off:int -> Linker.obj

(** [R_DrawSpan] — drawer #2 (34.0% of the frame at ~20 instrs/px compiled; the hand
    loop runs 13). Faithful to the shipped .i including the RANGECHECK I_Error path. *)
val span : off:(string -> int) -> str:(string -> int) -> Linker.obj

(** [R_DrawColumn] — drawer #3 (15.9% at ~17 instrs/px compiled; hand loop 11). *)
val column : off:(string -> int) -> str:(string -> int) -> Linker.obj

(** [dither_fs] — drawer #4: the fullscreen out2 kernel (the 2026-07-09 legibility
    pass). The compiled C paid ~120 instrs per (bn row, phase, slot) rank lookup —
    93% of the frame; the hand pair body runs ~17-20 per slot, every cut/mask/src
    offset an immediate, 3-cut slots skipping the padded 255 compare. Calls the C
    initializer [__dg_fs_build] once via the ready flag. *)
val dither_fs : lum_off:int -> cut_off:int -> mask_off:int -> ready_off:int -> Linker.obj

(** [__dg_frame_copy] — drawer #5 (feat/indexbuf): the hw-scanout path's per-frame
    block copy, 16000 words both ends word-aligned by contract, ~20 instrs/word
    naive-compiled vs ~2.3 hand (a 16-pair immediate-offset body). Leaf; clobbers
    R0-R3 only. *)
val frame_copy : Linker.obj

(** Every drawer whose data symbols resolve ([off] = {!Globals.offset_of_name},
    [str] = the interned-string table): each independent, missing symbols skip that
    drawer. The caller replaces same-named compiled objs with these at link set. *)
val build : off:(string -> int option) -> str:(string -> int option) -> Linker.obj list
