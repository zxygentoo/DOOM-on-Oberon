(** Hand-written replacements for the hottest C functions. Each drawer replaces the
    identically named compiled function at link time; the C stays in the tree as the
    spec — the jig diffs each drawer against gcc compiling that C, and the golden
    frames demand pixel identity with the host build. *)

(** [R_DrawSpan], including its RANGECHECK I_Error path. *)
val span : off:(string -> int) -> str:(string -> int) -> Linker.obj

(** [R_DrawColumn], including its RANGECHECK I_Error path. *)
val column : off:(string -> int) -> str:(string -> int) -> Linker.obj

(** [__dg_dither_fs] — the fullscreen kernel. The offsets are the DB-relative addresses
    of its C data ({!Globals.offset_of_name}): hand code reaches C data through DB, as
    compiled code does. Calls the C initializer [__dg_fs_build] once, via the ready
    flag. Clobbers R0-R5 and R12 (FP) beyond the standard caller-saved set; saves
    R6-R11 + LNK. *)
val dither_fs : lum_off:int -> cut_off:int -> mask_off:int -> ready_off:int -> Linker.obj

(** [__dg_frame_copy] — the hardware-scanout path's per-frame copy: 16000 words, both
    ends word-aligned by contract. Leaf; clobbers R0-R3 only. *)
val frame_copy : Linker.obj

(** Every drawer whose data symbols resolve ([off] = {!Globals.offset_of_name},
    [str] = the interned-string table): each independent, missing symbols skip that
    drawer. The caller replaces same-named compiled objs with these at link time. *)
val build : off:(string -> int option) -> str:(string -> int option) -> Linker.obj list
