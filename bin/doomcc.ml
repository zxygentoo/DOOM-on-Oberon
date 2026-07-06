(* doomcc — the whole-program driver (AGENT.md 1b): preprocessed C (.i) -> RISC5 blob.

   This is the *shape* of the full pipeline. The front (parse + amalgamate) and the middle
   (Globals placement + per-function Fundec compilation) are real; the back (the ABI §6
   instr-level linker + blob emit, track 3b) is stubbed. Until the later slices land (calls,
   control flow, memory), most functions gate-refuse — so for now doomcc doubles as a
   progress gauge: per merged program it reports how many functions compile and, for the
   rest, a histogram of *why* (each reason naming the slice that will unblock it).

   Usage:  doomcc <unit.i> [unit2.i ...] [-o out.blob]
   Preprocess first with spikes/cil/preprocess.sh (or gcc -E -std=gnu99). *)

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
  let inputs = List.rev !inputs in
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
  and n_instr = ref 0 in
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
         n_instr := !n_instr + Linker.code_size obj
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
  (* ---- (4) back end — STUB (ABI §6 / track 3b) ----
     The instr-level linker (label/branch resolution, LEA + FixedMul expansion, section
     layout, header + checksum, symbol map) turns the per-function instr lists + data/bss
     into the flat blob at 0x100000. Not built yet. *)
  Printf.printf "link:    TODO (ABI §6 / 3b) — would emit %s @ 0x100000\n" !out
;;
