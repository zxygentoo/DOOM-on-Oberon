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
