(* CIL spike driver — the DOOM.md §9 gate.

   Parse every preprocessed doomgeneric TU with goblint-cil, [Mergecil.merge]
   them into one file (the library-call replacement for single-TU
   amalgamation), and report what the gate cares about: parse failures,
   merge errors, alpha-renamed statics (the collisions PureDOOM renamed by
   hand), and the instr/function counts that scale the backend. Dumps the
   merged TU as C so host gcc can recompile it (round-trip check). *)

open GoblintCil

(* The target machine model (SEAM.md §4): ILP32, little-endian, char
   unsigned (LDB zero-extends; there is no sign-extending byte load).
   Start from goblint-cil's stock gcc 32-bit machdep and pin the two
   RISC5-specific choices. Selected with --risc5-machdep; must be set
   before initCIL. *)
let risc5_mach : Machdep.mach =
  match Machdep.gcc32 with
  | Some m -> { m with char_is_unsigned = true; little_endian = true }
  | None -> failwith "goblint-cil was built without a gcc32 machdep probe"

let () =
  let args = List.tl (Array.to_list Sys.argv) in
  let m32 = List.mem "--risc5-machdep" args in
  let inputs = List.filter (fun a -> a <> "--risc5-machdep") args in
  if m32 then envMachine := Some risc5_mach;
  initCIL ();
  Printf.printf
    "machdep: %s — int=%d long=%d ptr=%d%s\n"
    (if m32 then "RISC5 (ILP32)" else "host")
    (bitsSizeOf intType / 8)
    (bitsSizeOf longType / 8)
    (bitsSizeOf voidPtrType / 8)
    (match !envMachine with
     | Some m ->
       Printf.sprintf " char_unsigned=%b LE=%b" m.char_is_unsigned m.little_endian
     | None -> " (host defaults)");
  Printf.printf "parsing %d translation units\n%!" (List.length inputs);
  let failed = ref [] in
  let parsed =
    List.filter_map
      (fun f ->
        (* Errormsg.hadErrors is global and sticky: a file can "succeed" while
           having logged errors, and the stale flag then aborts every later
           parse. Reset per file; treat errors-with-a-result as failure. *)
        Errormsg.hadErrors := false;
        match Frontc.parse f () with
        | file when not !Errormsg.hadErrors -> Some file
        | _ ->
          failed := (f, "Errormsg errors (see stderr)") :: !failed;
          None
        | exception e ->
          failed := (f, Printexc.to_string e) :: !failed;
          None)
      inputs
  in
  Errormsg.hadErrors := false;
  List.iter (fun (f, e) -> Printf.printf "PARSE FAIL %s: %s\n" f e) !failed;
  Printf.printf "parsed ok: %d / %d\n%!" (List.length parsed) (List.length inputs);
  let merged = Mergecil.merge parsed "doom_merged" in
  Printf.printf
    "merge: %s\n%!"
    (if !Errormsg.hadErrors then "ERRORS (Errormsg.hadErrors)" else "clean");
  (* stats over the merged file *)
  let funs = ref 0
  and gvars = ref 0
  and decls = ref 0
  and renamed = ref [] in
  (* Mergecil resolves static collisions via alpha-renaming; the separator is
     "___" — scan merged global names for it. *)
  let has_sep name =
    let n = String.length name in
    let rec go i = i + 3 <= n && (String.sub name i 3 = "___" || go (i + 1)) in
    go 0
  in
  iterGlobals merged (fun g ->
    match g with
    | GFun (fd, _) ->
      incr funs;
      if has_sep fd.svar.vname then renamed := fd.svar.vname :: !renamed
    | GVar (vi, _, _) ->
      incr gvars;
      if has_sep vi.vname then renamed := vi.vname :: !renamed
    | GVarDecl _ -> incr decls
    | _ -> ());
  let instrs = ref 0
  and stmts = ref 0 in
  let counter =
    object
      inherit nopCilVisitor

      method! vinst _ =
        incr instrs;
        DoChildren

      method! vstmt _ =
        incr stmts;
        DoChildren
    end
  in
  visitCilFileSameGlobals counter merged;
  Printf.printf "function defs: %d   gvar defs: %d   extern decls: %d\n" !funs !gvars !decls;
  Printf.printf "CIL instrs: %d   stmts: %d\n" !instrs !stmts;
  (* classify: "__"-prefixed renames are glibc per-TU static-inline dups
     (byteswap/uint-identity etc.) — pure host-header noise, absent once the
     target mini-libc headers replace glibc. The rest are DOOM's own
     file-scope collisions (what PureDOOM renamed by hand). *)
  let doom_renames = List.filter (fun n -> not (String.length n >= 2 && String.sub n 0 2 = "__")) !renamed in
  Printf.printf
    "alpha-renamed globals: %d total (%d glibc-header dups, %d DOOM-real)\n"
    (List.length !renamed)
    (List.length !renamed - List.length doom_renames)
    (List.length doom_renames);
  List.iter (fun n -> Printf.printf "  DOOM rename: %s\n" n) doom_renames;
  (* ── 64-bit / float census (the SEAM §4 bans, verified rather than
     asserted). Walk the typed merged AST: every site whose type contains a
     64-bit integer (or any float) — formals, locals, globals, and each
     expression's result type — grouped by enclosing function, split
     DOOM-source vs glibc-header noise (the latter vanishes with the
     mini-libc headers). Under --risc5-machdep `long` is 32-bit, so only
     genuine ILongLong/IULongLong can trip the 64-bit check; typedef chains
     like int64_t unroll before testing. *)
  (* Trap, demonstrated live: host-LP64 stdint.h says [typedef long int
     int64_t] — under the 32-bit machdep that silently narrows to 32 bits,
     so a kind-only check (ILongLong) misses every int64_t site AND the
     merged AST is arithmetically wrong. Catch the *typedef name* too; the
     real pipeline avoids the trap by preprocessing against the target
     mini-libc headers. *)
  let name64 s =
    let n = String.length s in
    let rec go i = i + 2 <= n && ((s.[i] = '6' && s.[i + 1] = '4') || go (i + 1)) in
    go 0
  in
  (* Value-shape checks: does a value of this type force 64-bit (or float)
     representation on the backend? Deliberately does NOT recurse through
     pointers — a pointee's innards are the pointee's problem (all pointers
     are 32-bit), and descending would let glibc's FILE (which carries
     __off64_t fields) poison every function that touches stdio. By-value
     structs/arrays do recurse (their layout is the backend's problem). *)
  let rec val64 t =
    match t with
    | TInt ((ILongLong | IULongLong), _) -> true
    | TNamed (ti, _) -> name64 ti.tname || val64 ti.ttype
    | TArray (t', _, _) -> val64 t'
    | TComp (ci, _) -> List.exists (fun f -> val64 f.ftype) ci.cfields
    | _ -> false
  and valf t =
    match t with
    | TFloat _ -> true
    | TNamed (ti, _) -> valf ti.ttype
    | TArray (t', _, _) -> valf t'
    | TComp (ci, _) -> List.exists (fun f -> valf f.ftype) ci.cfields
    | _ -> false
  in
  let contains64 = val64
  and containsf = valf in
  let in_doom (l : location) =
    (* merged locations point back at original sources via #line markers *)
    let f = l.file in
    let n = String.length f and p = "doomgeneric/" in
    let pl = String.length p in
    let rec go i = i + pl <= n && (String.sub f i pl = p || go (i + 1)) in
    go 0
  in
  let doom64 : (string, int) Hashtbl.t = Hashtbl.create 16
  and doomf : (string, int) Hashtbl.t = Hashtbl.create 16
  and doombf_acc : (string, int) Hashtbl.t = Hashtbl.create 16
  and libc64 = ref 0
  and libcf = ref 0
  and libcbf_acc = ref 0 in
  let bump tbl k =
    Hashtbl.replace tbl k (1 + Option.value ~default:0 (Hashtbl.find_opt tbl k))
  in
  let census_fun (fd : fundec) =
    let where =
      Printf.sprintf "%s (%s:%d)" fd.svar.vname fd.svar.vdecl.file fd.svar.vdecl.line
    in
    let doom = in_doom fd.svar.vdecl in
    let note t =
      if contains64 t then if doom then bump doom64 where else incr libc64;
      if containsf t then if doom then bump doomf where else incr libcf
    in
    List.iter (fun vi -> note vi.vtype) (fd.sformals @ fd.slocals);
    let v =
      object
        inherit nopCilVisitor

        method! vexpr e =
          (try note (typeOf e) with _ -> ());
          DoChildren

        (* bitfield *accesses*: the thing the backend would actually have
           to codegen (shift/mask loads, read-modify-write stores) *)
        method! vlval (_, off) =
          let rec walk = function
            | NoOffset -> ()
            | Field (fi, o) ->
              if fi.fbitfield <> None
              then if doom then bump doombf_acc where else incr libcbf_acc;
              walk o
            | Index (_, o) -> walk o
          in
          walk off;
          DoChildren
      end
    in
    ignore (visitCilFunction v fd)
  in
  iterGlobals merged (fun g ->
    match g with
    | GFun (fd, _) -> census_fun fd
    | GVar (vi, _, _) | GVarDecl (vi, _) ->
      if contains64 vi.vtype
      then
        if in_doom vi.vdecl
        then
          bump
            doom64
            (Printf.sprintf "global %s (%s:%d)" vi.vname vi.vdecl.file vi.vdecl.line)
        else incr libc64
    | _ -> ());
  Printf.printf "64-bit census — DOOM-source sites (by function):\n";
  if Hashtbl.length doom64 = 0
  then Printf.printf "  none\n"
  else Hashtbl.iter (fun k n -> Printf.printf "  %s: %d typed sites\n" k n) doom64;
  Printf.printf "float census — DOOM-source sites (by function):\n";
  if Hashtbl.length doomf = 0
  then Printf.printf "  none\n"
  else Hashtbl.iter (fun k n -> Printf.printf "  %s: %d typed sites\n" k n) doomf;
  Printf.printf
    "glibc-header noise (ignored; mini-libc removes): %d 64-bit, %d float sites\n"
    !libc64
    !libcf;
  (* ── bitfield census (SEAM §4's third ban, same treatment): any composite
     whose fields carry explicit bit widths. Bitfields have no portable
     layout (direction/unit/straddle/signedness all implementation-defined),
     and supporting them means defining a bitfield ABI in the backend —
     verify DOOM needs none. *)
  let doombf = ref []
  and libcbf = ref 0 in
  iterGlobals merged (fun g ->
    match g with
    | GCompTag (ci, loc) ->
      let bfs = List.filter (fun f -> f.fbitfield <> None) ci.cfields in
      if bfs <> []
      then
        if in_doom loc
        then
          doombf
          := Printf.sprintf
               "%s %s (%s:%d): %s"
               (if ci.cstruct then "struct" else "union")
               ci.cname
               loc.file
               loc.line
               (String.concat
                  ", "
                  (List.map
                     (fun f ->
                       Printf.sprintf
                         "%s:%d"
                         f.fname
                         (Option.value ~default:(-1) f.fbitfield))
                     bfs))
             :: !doombf
        else incr libcbf
    | _ -> ());
  Printf.printf "bitfield census — DOOM-source composites:\n";
  if !doombf = []
  then Printf.printf "  none\n"
  else List.iter (fun s -> Printf.printf "  %s\n" s) !doombf;
  Printf.printf "glibc-header composites with bitfields (ignored): %d\n" !libcbf;
  Printf.printf "bitfield accesses — DOOM-source sites (by function):\n";
  if Hashtbl.length doombf_acc = 0
  then Printf.printf "  none\n"
  else Hashtbl.iter (fun k n -> Printf.printf "  %s: %d accesses\n" k n) doombf_acc;
  Printf.printf "glibc-header bitfield accesses (ignored): %d\n" !libcbf_acc;
  let out = if m32 then "out/merged_m32.c" else "out/merged.c" in
  let oc = open_out out in
  dumpFile defaultCilPrinter oc out merged;
  close_out oc;
  Printf.printf "wrote %s\n%!" out
