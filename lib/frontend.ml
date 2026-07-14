(* goblint-cil front end for the RISC5 target: the machine model (ABI §4) and parsing C
   into the typed AST the backend consumes. Mirrors the spike's driver
   (the §9 CIL spike, cil-spike.md); owns the machdep so the whole toolchain shares one. *)

open GoblintCil

(* ABI §4: ILP32, little-endian, char unsigned. Pin the two RISC5 choices onto
   goblint-cil's stock gcc-32 machdep; must be installed before initCIL. *)
let risc5_mach : Machdep.mach =
  match Machdep.gcc32 with
  | Some m -> { m with char_is_unsigned = true; little_endian = true }
  | None -> failwith "goblint-cil built without a gcc32 machdep probe"
;;

let initialized = ref false

let ensure_init () =
  if not !initialized
  then (
    envMachine := Some risc5_mach;
    initCIL ();
    initialized := true)
;;

(* Parse one preprocessed translation unit (.i). *)
let parse_file (path : string) : file =
  ensure_init ();
  Errormsg.hadErrors := false;
  let file = Frontc.parse path () in
  if !Errormsg.hadErrors then failwith ("CIL parse errors in " ^ path);
  file
;;

(* Parse a self-contained C snippet (no #include / no macros — headerless int code is
   already "preprocessed") into a Cil.file. *)
let parse_string ~(name : string) (src : string) : file =
  let tmp = Filename.temp_file name ".c" in
  Fun.protect
    ~finally:(fun () -> Sys.remove tmp)
    (fun () ->
       let oc = open_out tmp in
       output_string oc src;
       close_out oc;
       parse_file tmp)
;;

(* Amalgamate parsed units into one (Mergecil.merge — the single-TU / PureDOOM rename step,
   spike-proven at full scale — cil-spike.md). *)
let merge (units : file list) ~(name : string) : file =
  Errormsg.hadErrors := false;
  let m = Mergecil.merge units name in
  if !Errormsg.hadErrors then failwith "CIL merge errors";
  m
;;

(* The (single) function definition named [fname] in [file]. *)
let find_fundec (file : file) (fname : string) : fundec =
  let found = ref None in
  iterGlobals file (function
    | GFun (fd, _) when fd.svar.vname = fname -> found := Some fd
    | _ -> ());
  match !found with
  | Some fd -> fd
  | None -> failwith (Printf.sprintf "function %s not found in parsed unit" fname)
;;

let fundecs (file : file) : fundec list =
  let acc = ref [] in
  iterGlobals file (function
    | GFun (fd, _) -> acc := fd :: !acc
    | _ -> ());
  List.rev !acc
;;
