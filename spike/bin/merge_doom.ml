(* CIL spike driver — the DOOM.md §9 gate.

   Parse every preprocessed doomgeneric TU with goblint-cil, [Mergecil.merge]
   them into one file (the library-call replacement for single-TU
   amalgamation), and report what the gate cares about: parse failures,
   merge errors, alpha-renamed statics (the collisions PureDOOM renamed by
   hand), and the instr/function counts that scale the backend. Dumps the
   merged TU as C so host gcc can recompile it (round-trip check). *)

open GoblintCil

let () =
  initCIL ();
  let inputs = List.tl (Array.to_list Sys.argv) in
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
  let oc = open_out "out/merged.c" in
  dumpFile defaultCilPrinter oc "out/merged.c" merged;
  close_out oc;
  Printf.printf "wrote out/merged.c\n%!"
