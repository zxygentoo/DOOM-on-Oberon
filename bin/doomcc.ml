(* doomcc — the whole-program driver (DOOM.md 1b): preprocessed C (.i) -> RISC5 blob.

   This is the *shape* of the full pipeline. The front (parse + amalgamate) and the middle
   (per-function codegen, via Backend.Codegen) are real; the back (the SEAM §6 instr-level
   linker + blob emit, track 3b) is stubbed. Until the later codegen slices land (calls,
   control flow, memory), most functions gate-refuse — so for now doomcc doubles as a
   progress gauge: per merged program it reports how many functions compile and, for the
   rest, a histogram of *why* (each reason naming the slice that will unblock it).

   Usage:  doomcc <unit.i> [unit2.i ...] [-o out.blob]
   Preprocess first with spikes/cil/preprocess.sh (or gcc -E -std=gnu99). *)

module C = GoblintCil

let () =
  (* ---- args: preprocessed .i inputs, optional -o ---- *)
  let out = ref "doom.blob"
  and inputs = ref [] in
  let rec args = function
    | "-o" :: o :: rest ->
      out := o;
      args rest
    | f :: rest ->
      inputs := f :: !inputs;
      args rest
    | [] -> ()
  in
  args (List.tl (Array.to_list Sys.argv));
  let inputs = List.rev !inputs in
  if inputs = []
  then begin
    prerr_endline "usage: doomcc <unit.i> [unit2.i ...] [-o out.blob]";
    exit 2
  end;
  (* ---- (1) front end: parse each TU, amalgamate to one unit (the PureDOOM rename step) ---- *)
  let units = List.map Backend.Frontend.parse_file inputs in
  let merged = Backend.Frontend.merge units ~name:"doom" in
  Printf.printf "front:   merged %d translation unit(s)\n" (List.length units);
  (* ---- (2)+(3) walk the merged unit: codegen each function; collect data/bss ----
     compile_fundec is slice-1 (straight-line int leaves); the gate refuses the rest,
     naming the slice that will handle it. (Globals: TODO 3b — data / bss / helpers.) *)
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
      (match Backend.Codegen.compile_fundec fd with
       | instrs ->
         incr ok;
         n_instr := !n_instr + List.length instrs
       | exception Backend.Codegen.Unsupported msg ->
         incr rejected;
         bump msg)
    | C.GVar _ | C.GVarDecl _ -> () (* TODO(3b): data / bss / extern-helper resolution *)
    | _ -> ());
  Printf.printf
    "codegen: %d functions — %d compiled (%d instrs), %d gate-refused\n"
    !total
    !ok
    !n_instr
    !rejected;
  if !rejected > 0
  then begin
    Printf.printf "         why the rest don't compile yet (the slice worklist):\n";
    Hashtbl.fold (fun k n acc -> (n, k) :: acc) reasons []
    |> List.sort (fun a b -> compare (fst b) (fst a))
    |> List.iter (fun (n, k) -> Printf.printf "         %5d  %s\n" n k)
  end;
  (* ---- (4) back end — STUB (SEAM §6 / track 3b) ----
     The instr-level linker (label/branch resolution, LEA + FixedMul expansion, section
     layout, header + checksum, symbol map) turns the per-function instr lists + data/bss
     into the flat blob at 0x100000. Not built yet. *)
  Printf.printf "link:    TODO (SEAM §6 / 3b) — would emit %s @ 0x100000\n" !out
