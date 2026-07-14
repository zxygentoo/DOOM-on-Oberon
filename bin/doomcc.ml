(* doomcc — the whole-program driver (AGENT.md 1b): preprocessed C (.i) -> RISC5 blob.

   The full pipeline: parse + amalgamate (Frontend) · data/bss layout (Globals) ·
   per-function compilation (Fundec) · whole-program link at BLOB_BASE with crt0 thunks
   and Runtime helpers (Linker/Crt0/Runtime) · the ABI §7 blob file + symbol map (Blob).
   Functions the gate still refuses are histogrammed by reason (each names its pending
   slice) and their symbols become one-word self-loop traps, alongside the undefined
   imports the mini-libc will provide — that printed list is the 1c worklist.

   Usage:  doomcc <unit.i> [unit2.i ...] [-o out.blob]
   Preprocess first with ./preprocess.sh (or gcc -E -std=gnu99). *)

module C = GoblintCil
open Doomcc_core

let () =
  (* ---- args: preprocessed .i inputs, optional -o ---- *)
  let out = ref "doom.blob"
  and inputs = ref [] in
  let rec parse_args = function
    | "-o" :: o :: rest ->
      out := o;
      parse_args rest
    | f :: rest ->
      inputs := f :: !inputs;
      parse_args rest
    | [] -> ()
  in
  parse_args (List.tl (Array.to_list Sys.argv));
  (* m_fixed.c is replaced WHOLESALE (AGENT.md §4): its int64_t code arrives via the
     host-preprocessed .i as 32-bit `long` — a silent miscompile, not a refusal — so
     the file is skipped unconditionally: FixedMul is the ABI §5 linker intrinsic,
     FixedDiv comes from libc/fixed.c. Encoded here so no invocation can forget. *)
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
  (* ---- (1) front end: parse each TU, amalgamate to one unit (the PureDOOM rename step) ---- *)
  let units = List.map Frontend.parse_file inputs in
  let merged = Frontend.merge units ~name:"doom" in
  Printf.printf "front:   merged %d translation unit(s)\n" (List.length units);
  (* ---- (2) data/bss layout: every placeable global gets a DB-relative offset; the
     unplaceable ones are skipped-with-reason and refuse per touching function ---- *)
  let globals = Globals.from_file merged in
  Printf.printf
    "data:    %d globals placed, %d B data+bss image (DB-relative), %d ptr relocs, %d \
     skipped\n"
    (Hashtbl.length globals.Globals.offsets)
    (Bytes.length globals.Globals.image)
    (List.length globals.Globals.relocs)
    (Hashtbl.length globals.Globals.skipped);
  (* ---- (3) walk the merged unit: compile each function ----
     Fundec.compile covers the landed slices (straight-line, control flow, scalar
     globals); Check refuses the rest, naming the slice that will handle it. *)
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
       | exception C.SizeOfError (why, _) ->
         incr rejected;
         bump ("sizeof failed (incomplete type?): " ^ why))
    | C.GVar _ | C.GVarDecl _ ->
      () (* handled by Globals above (GVarDecl-only = extern) *)
    | _ -> ());
  Printf.printf
    "codegen: %d functions — %d compiled (%d instrs), %d gate-refused\n"
    !total
    !ok
    !n_instr
    !rejected;
  if !rejected > 0
  then (
    Printf.printf "         why the rest don't compile yet (the slice worklist):\n";
    Hashtbl.fold (fun k n acc -> (n, k) :: acc) reasons []
    |> List.sort (fun a b -> compare (fst b) (fst a))
    |> List.iter (fun (n, k) -> Printf.printf "         %5d  %s\n" n k));
  (* ---- (4) link + emit (3b.2, ABI §6/§7/§8) ----
     Whole-program link at BLOB_BASE. Symbols referenced but not defined — libc imports
     the mini-libc will provide, plus any still-refused function — get a self-loop trap
     stub so the layout closes, and the list is printed: it IS the mini-libc worklist.
     Entry offsets stay 0 until the crt0 thunks land (the hello-blob slice). *)
  let objs = List.rev !objs @ Runtime.objs in
  (* the 1a drawer swap: the flat profile priced __dg_dither at 38% of the frame under
     naive codegen; the hand-rolled obj (lib/drawers.ml, ~10 instrs/px) replaces the
     compiled one. dither.c's C version stays the spec — the jig diffs the hand code
     against gcc compiling it, the golden oracle against the glibc-built host frames. *)
  let objs =
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
             "drawers: %s hand-rolled (1a) — compiled version replaced\n"
             d.Linker.name)
        drawers;
      let names = List.map (fun (d : Linker.obj) -> d.Linker.name) drawers in
      List.filter (fun (o : Linker.obj) -> not (List.mem o.Linker.name names)) objs
      @ drawers)
  in
  let defined = Hashtbl.create 256 in
  List.iter (fun (o : Linker.obj) -> Hashtbl.replace defined o.Linker.name ()) objs;
  let missing = Hashtbl.create 64 in
  let note_ref name =
    (* intrinsics resolve by inline expansion, not by a defining object (ABI §5) *)
    if (not (Hashtbl.mem defined name)) && not (Linker.is_intrinsic name)
    then Hashtbl.replace missing name ()
  in
  List.iter
    (fun (o : Linker.obj) ->
       List.iter
         (function
           | Linker.Call n | Linker.Addr (_, n) -> note_ref n
           | _ -> ())
         o.Linker.frags)
    objs;
  List.iter
    (function
      | _, Globals.Code n -> note_ref n
      | _, Globals.Data _ -> ())
    globals.Globals.relocs;
  let missing = List.sort compare (Hashtbl.fold (fun k () acc -> k :: acc) missing []) in
  let traps =
    List.map
      (fun name -> { Linker.name; frags = [ Linker.Label 0; Linker.Jmp 0 ] })
      missing
  in
  if missing <> []
  then (
    Printf.printf
      "link:    %d undefined symbols -> self-loop traps (the mini-libc worklist):\n"
      (List.length missing);
    Printf.printf "         %s\n" (String.concat " " missing));
  (* crt0 thunks (ABI §7) for each entry whose C symbol exists — the 1c port layer will
     provide Init/Tick/KeyIn; until then the header fields stay 0. Thunk size is a
     constant, so the code section is sizable before the layout the thunks bake in. *)
  let entry_names =
    List.filter (fun n -> Hashtbl.mem defined n) [ "Init"; "Tick"; "KeyIn" ]
  in
  let stack_top =
    0x300000
    (* STACK_TOP, ABI §8 *)
  in
  let all = objs @ traps in
  let code_words =
    List.fold_left (fun a o -> a + Linker.code_size o) 0 all
    + (Crt0.size * List.length entry_names)
  in
  let data_size = globals.Globals.data_size in
  let bss_size = Bytes.length globals.Globals.image - data_size in
  let save_bss = if entry_names = [] then 0 else Crt0.save_area_size in
  let base =
    0x100000
    (* BLOB_BASE, ABI §8 *)
  in
  let layout = Blob.layout ~base ~code_words ~data_size ~bss_size:(bss_size + save_bss) in
  let thunks =
    List.map
      (fun n ->
         Crt0.thunk
           ~name:("__crt0_" ^ n)
           ~entry:n
           ~save_area:(layout.Blob.bss_base + bss_size)
           ~stack_top
           ~data_base:layout.Blob.data_base)
      entry_names
  in
  let all = all @ thunks in
  if layout.Blob.bss_base + layout.Blob.bss_length > 0x2C0000
  then
    Printf.printf
      "link:    WARNING blob end 0x%X exceeds the 1.75 MB cap (ABI §8)\n"
      (layout.Blob.bss_base + layout.Blob.bss_length);
  let image = Linker.link ~code_base:layout.Blob.code_base all in
  (* the data section, pointer relocs patched to absolute addresses (ABI §6) *)
  let data = Bytes.sub globals.Globals.image 0 data_size in
  List.iter
    (fun (off, target) ->
       let v =
         match target with
         | Globals.Data t -> layout.Blob.data_base + t
         | Globals.Code name -> Linker.sym_addr image name
       in
       Bytes.set_int32_le data off (Int32.of_int v))
    globals.Globals.relocs;
  (* header entries point at the thunks, not the C functions — the thunk owns the world
     switch (ABI §7); 0 while the port layer's C entry doesn't exist yet *)
  let entry name =
    match List.assoc_opt ("__crt0_" ^ name) image.Linker.symbols with
    | Some off -> layout.Blob.code_base + (4 * off) - base
    | None -> 0
  in
  let blob =
    Blob.emit
      ~layout
      ~code:image.Linker.code
      ~data
      ~entries:(entry "Init", entry "Tick", entry "KeyIn")
  in
  let oc = open_out_bin !out in
  output_bytes oc blob;
  close_out oc;
  let map = !out ^ ".map" in
  let oc = open_out map in
  Printf.fprintf oc "# %s — symbol map (absolute byte addresses)\n" !out;
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
  close_out oc;
  Printf.printf
    "link:    code %d words · data %d B · bss %d B · image %d B @ 0x%X\n"
    code_words
    data_size
    bss_size
    layout.Blob.image_length
    base;
  Printf.printf "emit:    %s (+ %s)\n" !out map
;;
