(* doomcc — the whole-program driver: preprocessed C -> the RISC5 blob.

   Parses and merges the units (Frontend), lays out data and bss (Globals), compiles
   each function (Fundec), swaps in the hand-written drawers, links at BLOB_BASE with
   the crt0 entry thunks and the runtime helpers, and writes the ABI §7 blob plus its
   symbol map. Functions Check refuses are counted by reason; they and every other
   undefined symbol link as one-word self-loop traps, so reaching one hangs where
   run_blob can name it.

   Usage:  doomcc <unit.i>... [-o out.blob]     (default doom.blob; map: <out>.map)
   Units are gcc -E -std=gnu99 output — `make i` builds DOOM's — or preprocessor-free
   C such as libc/*.c. *)

module C = GoblintCil
open Doomcc_core
module AC = Abi_constants

(* m_fixed.i is dropped here, where no invocation can forget it: host preprocessing
   spells its int64_t as x86-64 `long`, which ILP32 sizes at 32 bits, so it would
   compile silently wrong. FixedMul is the linker intrinsic (ABI §5) and FixedDiv
   comes from libc/fixed.c. *)
let parse_args argv : string list * string =
  let out = ref "doom.blob"
  and inputs = ref [] in
  let rec go = function
    | "-o" :: o :: rest ->
      out := o;
      go rest
    | f :: rest ->
      inputs := f :: !inputs;
      go rest
    | [] -> ()
  in
  go argv;
  let inputs, skipped_fixed =
    List.partition (fun f -> Filename.basename f <> "m_fixed.i") (List.rev !inputs)
  in
  if skipped_fixed <> []
  then
    Printf.printf
      "front:   m_fixed.i skipped — replaced by the FixedMul intrinsic + libc/fixed.c \
       (ABI §5)\n";
  if inputs = []
  then (
    prerr_endline "usage: doomcc <unit.i> [unit2.i ...] [-o out.blob]";
    exit 2);
  inputs, !out
;;

let parse_and_merge (inputs : string list) : C.file =
  let units = List.map Frontend.parse_file inputs in
  let merged = Frontend.merge units ~name:"doom" in
  Printf.printf "front:   merged %d translation unit(s)\n" (List.length units);
  merged
;;

(* An unplaceable global doesn't fail the build: each function touching it refuses. *)
let layout_globals (merged : C.file) : Globals.t =
  let globals = Globals.from_file merged in
  Printf.printf
    "data:    %d globals placed, %d B data+bss image (DB-relative), %d ptr relocs, %d \
     skipped\n"
    (Hashtbl.length globals.Globals.offsets)
    (Bytes.length globals.Globals.image)
    (List.length globals.Globals.relocs)
    (Hashtbl.length globals.Globals.skipped);
  globals
;;

let compile_functions ~(globals : Globals.t) (merged : C.file) : Linker.obj list =
  let total = ref 0
  and ok = ref 0
  and rejected = ref 0
  and n_instr = ref 0
  and objs = ref [] in
  let reasons : (string, int) Hashtbl.t = Hashtbl.create 32 in
  let bump k =
    Hashtbl.replace reasons k (1 + Option.value ~default:0 (Hashtbl.find_opt reasons k))
  in
  C.iterGlobals merged (fun g ->
    match g with
    | C.GFun (fd, _) ->
      incr total;
      (match Fundec.compile ~globals fd with
       | obj ->
         incr ok;
         n_instr := !n_instr + Linker.code_size obj;
         objs := obj :: !objs
       | exception Check.Unsupported msg ->
         incr rejected;
         bump msg
       | exception Check.Internal msg ->
         (* a doomcc bug, not a refusal: fail the build instead of trapping it *)
         Printf.eprintf "doomcc: internal error compiling %s: %s\n" fd.svar.vname msg;
         exit 3
       | exception C.SizeOfError (why, _) ->
         incr rejected;
         bump ("sizeof failed (incomplete type?): " ^ why))
    | C.GVar _ | C.GVarDecl _ -> () (* placed by layout_globals *)
    | _ -> ());
  Printf.printf
    "codegen: %d functions — %d compiled (%d instrs), %d gate-refused\n"
    !total
    !ok
    !n_instr
    !rejected;
  if !rejected > 0
  then (
    Printf.printf "         refused, by reason:\n";
    Hashtbl.fold (fun k n acc -> (n, k) :: acc) reasons []
    |> List.sort (fun a b -> compare (fst b) (fst a))
    |> List.iter (fun (n, k) -> Printf.printf "         %5d  %s\n" n k));
  List.rev !objs
;;

(* The hand-written drawers (lib/drawers.ml) replace their compiled versions, and only
   where the C was compiled: the C stays the spec, and the jig diffs each drawer
   against gcc compiling it. *)
let swap_drawers ~(globals : Globals.t) ~(merged : C.file) (objs : Linker.obj list)
  : Linker.obj list
  =
  let off name = Globals.offset_of_name globals merged name in
  let str l = Hashtbl.find_opt globals.Globals.strings l in
  let drawers =
    List.filter
      (fun (d : Linker.obj) ->
         List.exists (fun (o : Linker.obj) -> o.Linker.name = d.Linker.name) objs)
      (Drawers.build ~off ~str)
  in
  if drawers = []
  then objs
  else (
    List.iter
      (fun (d : Linker.obj) ->
         Printf.printf
           "drawers: %s hand-rolled — compiled version replaced\n"
           d.Linker.name)
      drawers;
    let names = List.map (fun (d : Linker.obj) -> d.Linker.name) drawers in
    List.filter (fun (o : Linker.obj) -> not (List.mem o.Linker.name names)) objs
    @ drawers)
;;

(* Referenced but defined nowhere: the refused functions and anything no unit
   provides. Each becomes a trap (see the header). *)
let undefined_symbols ~(globals : Globals.t) (objs : Linker.obj list) : string list =
  let defined = Hashtbl.create 256 in
  List.iter (fun (o : Linker.obj) -> Hashtbl.replace defined o.Linker.name ()) objs;
  let missing = Hashtbl.create 64 in
  let note_ref name =
    (* intrinsics expand inline; nothing defines them *)
    if (not (Hashtbl.mem defined name)) && not (Linker.is_intrinsic name)
    then Hashtbl.replace missing name ()
  in
  List.iter (fun (o : Linker.obj) -> List.iter note_ref (Linker.referenced_syms o)) objs;
  List.iter
    (function
      | _, Globals.Code n -> note_ref n
      | _, Globals.Data _ -> ())
    globals.Globals.relocs;
  let missing = List.sort compare (Hashtbl.fold (fun k () acc -> k :: acc) missing []) in
  if missing <> []
  then (
    Printf.printf
      "link:    %d undefined symbols -> self-loop traps:\n"
      (List.length missing);
    Printf.printf "         %s\n" (String.concat " " missing));
  missing
;;

let trap name : Linker.obj = { Linker.name; frags = [ Linker.Label 0; Linker.Jmp 0 ] }

(* The thunks bake in layout addresses (save area, data base), but the layout needs
   the code size first; Crt0.size being a constant breaks the cycle. One thunk per
   entry whose C function exists. *)
let link_program ~(globals : Globals.t) (objs : Linker.obj list) (traps : Linker.obj list)
  : Blob.layout * Linker.image * int
  =
  let entry_names =
    List.filter
      (fun n -> List.exists (fun (o : Linker.obj) -> o.Linker.name = n) objs)
      [ "Init"; "Tick"; "KeyIn" ]
  in
  let all = objs @ traps in
  let code_words =
    List.fold_left (fun a o -> a + Linker.code_size o) 0 all
    + (Crt0.size * List.length entry_names)
  in
  let data_size = globals.Globals.data_size in
  let bss_size = Bytes.length globals.Globals.image - data_size in
  let save_bss = if entry_names = [] then 0 else Crt0.save_area_size in
  let layout =
    Blob.layout ~base:AC.blob_base ~code_words ~data_size ~bss_size:(bss_size + save_bss)
  in
  let thunks =
    List.map
      (fun n ->
         Crt0.thunk
           ~name:("__crt0_" ^ n)
           ~entry:n
           ~save_area:(layout.Blob.bss_base + bss_size)
           ~stack_top:AC.stack_top
           ~data_base:layout.Blob.data_base)
      entry_names
  in
  if layout.Blob.bss_base + layout.Blob.bss_length > AC.blob_end_cap
  then (
    Printf.eprintf
      "doomcc: blob end 0x%X exceeds the 1.75 MB cap 0x%X (ABI §8: bss would run into \
       the C stack)\n"
      (layout.Blob.bss_base + layout.Blob.bss_length)
      AC.blob_end_cap;
    exit 1);
  let image = Linker.link ~code_base:layout.Blob.code_base (all @ thunks) in
  layout, image, code_words
;;

(* The data section, pointer relocs patched to absolute addresses (ABI §6). *)
let patched_data ~(globals : Globals.t) ~(layout : Blob.layout) (image : Linker.image)
  : bytes
  =
  let data = Bytes.sub globals.Globals.image 0 globals.Globals.data_size in
  List.iter
    (fun (off, target) ->
       let v =
         match target with
         | Globals.Data t -> layout.Blob.data_base + t
         | Globals.Code name -> Linker.sym_addr image name
       in
       Bytes.set_int32_le data off (Int32.of_int v))
    globals.Globals.relocs;
  data
;;

(* Header entries point at the thunks, not the C functions: the thunk owns the switch
   into C (stack, DB, Oberon's registers saved). 0 = no such entry. *)
let write_blob ~out ~(globals : Globals.t) ~(layout : Blob.layout) (image : Linker.image)
  : unit
  =
  let entry name =
    match Linker.find_sym_addr image ("__crt0_" ^ name) with
    | Some addr -> addr - layout.Blob.base
    | None -> 0
  in
  let blob =
    Blob.emit
      ~layout
      ~code:image.Linker.code
      ~data:(patched_data ~globals ~layout image)
      ~entries:(entry "Init", entry "Tick", entry "KeyIn")
  in
  let oc = open_out_bin out in
  output_bytes oc blob;
  close_out oc
;;

(* The symbol map: "# ..." header lines, then "0xADDR name" per code symbol,
   ascending — what run_blob's -profile parses and humans grep. *)
let write_map ~path ~out ~(layout : Blob.layout) (image : Linker.image) : unit =
  let oc = open_out path in
  Printf.fprintf oc "# %s — symbol map (absolute byte addresses)\n" out;
  Printf.fprintf
    oc
    "# base 0x%X  code 0x%X  data 0x%X  bss 0x%X+%d  image %d B\n"
    layout.Blob.base
    layout.Blob.code_base
    layout.Blob.data_base
    layout.Blob.bss_base
    layout.Blob.bss_length
    layout.Blob.image_length;
  List.iter
    (fun (name, off) ->
       Printf.fprintf oc "0x%06X %s\n" (layout.Blob.code_base + (4 * off)) name)
    image.Linker.symbols;
  close_out oc
;;

let () =
  let inputs, out = parse_args (List.tl (Array.to_list Sys.argv)) in
  let merged = parse_and_merge inputs in
  let globals = layout_globals merged in
  let objs =
    swap_drawers ~globals ~merged (compile_functions ~globals merged @ Runtime.objs)
  in
  let missing = undefined_symbols ~globals objs in
  let layout, image, code_words = link_program ~globals objs (List.map trap missing) in
  write_blob ~out ~globals ~layout image;
  let map = out ^ ".map" in
  write_map ~path:map ~out ~layout image;
  Printf.printf
    "link:    code %d words · data %d B · bss %d B · image %d B @ 0x%X\n"
    code_words
    globals.Globals.data_size
    (Bytes.length globals.Globals.image - globals.Globals.data_size)
    layout.Blob.image_length
    layout.Blob.base;
  Printf.printf "emit:    %s (+ %s)\n" out map
;;
