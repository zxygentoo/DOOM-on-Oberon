open GoblintCil

(* goblint-cil's gcc-32 machdep with the two RISC5 choices; must be installed before
   initCIL *)
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
    (* a Call's destination has exactly the callee's return type — CIL routes any
       conversion through a temporary (x = f() becomes tmp = f(); x = (T)tmp). Fundec's
       call-result move (MOV home, R0) relies on it: it never narrows. goblint-cil's
       default, pinned so a library change can't quietly flip it *)
    Cabs2cil.doCollapseCallCast := false;
    initCIL ();
    initialized := true)
;;

let parse_file (path : string) : file =
  ensure_init ();
  Errormsg.hadErrors := false;
  let file = Frontc.parse path () in
  if !Errormsg.hadErrors then failwith ("CIL parse errors in " ^ path);
  file
;;

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

let merge (units : file list) ~(name : string) : file =
  Errormsg.hadErrors := false;
  let m = Mergecil.merge units name in
  if !Errormsg.hadErrors then failwith "CIL merge errors";
  m
;;

let fundecs (file : file) : fundec list =
  let acc = ref [] in
  iterGlobals file (function
    | GFun (fd, _) -> acc := fd :: !acc
    | _ -> ());
  List.rev !acc
;;
