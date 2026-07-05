(* Slice-1 differential jig (DOOM.md §7/§9): compile small C leaves with OUR backend, run
   them in the emulator, and diff R0 against host gcc over edge + random int args. gcc's
   [int] is 32-bit on x86-64, matching RISC5, so int-only samples must agree bit-for-bit.

   This is the harness the backend grows against: each new codegen feature adds a sample and
   is trusted only once it matches gcc here. Parse+codegen and gcc-compile both happen once
   per sample; only the (fast) runs repeat per arg-tuple. *)

let u32 x = x land 0xFFFF_FFFF

(* ---- our side: parse -> codegen (once per sample) ---- *)
let our_compile ~src ~fname =
  let file = Backend.Frontend.parse_string ~name:fname src in
  let fd = Backend.Frontend.find_fundec file fname in
  Backend.Codegen.compile_fundec fd

(* ---- gcc oracle: compile [src] + a tiny argv driver once, then run the exe per tuple ---- *)
let gcc_compile ~src ~fname ~arity : string =
  let cfile = Filename.temp_file "jig" ".c" in
  let exe = cfile ^ ".exe" in
  let oc = open_out cfile in
  output_string oc src;
  output_string oc "\n#include <stdio.h>\n#include <stdlib.h>\n";
  let params = List.init arity (fun i -> Printf.sprintf "(int)strtol(argv[%d],0,10)" (i + 1)) in
  Printf.fprintf oc
    "int main(int argc,char**argv){(void)argc;printf(\"%%d\\n\",%s(%s));return 0;}\n"
    fname
    (String.concat "," params);
  close_out oc;
  let cmd =
    Printf.sprintf "gcc -std=gnu99 -w -O0 %s -o %s" (Filename.quote cfile) (Filename.quote exe)
  in
  if Sys.command cmd <> 0 then failwith ("gcc failed for " ^ fname);
  Sys.remove cfile;
  exe

let gcc_run exe (args : int list) : int =
  let cmd =
    Printf.sprintf "%s %s" (Filename.quote exe) (String.concat " " (List.map string_of_int args))
  in
  let ic = Unix.open_process_in cmd in
  let line = try input_line ic with End_of_file -> "" in
  ignore (Unix.close_process_in ic);
  u32 (int_of_string (String.trim line))

(* ---- samples: each is (source, name, arity); every op below is slice-1 supported ---- *)
let samples =
  [ "int add(int a,int b){ return a+b; }", "add", 2
  ; "int sub(int a,int b){ return a-b; }", "sub", 2
  ; "int mul(int a,int b){ return a*b; }", "mul", 2
  ; "int bitops(int a,int b){ return (a & b) | (a ^ b); }", "bitops", 2
  ; "int shl(int a){ return a << 3; }", "shl", 1
  ; "int sar(int a){ return a >> 1; }", "sar", 1 (* signed: arithmetic shift right *)
  ; "int mix(int a,int b,int c){ int t = a*b; return t - c + 7; }", "mix", 3
  ; "int bigc(int a){ return a + 100000; }", "bigc", 1 (* exercises the 32-bit load_const *)
  ; "int negx(int a){ return -a; }", "negx", 1
  ; "int notx(int a){ return ~a; }", "notx", 1
  ]

(* The pre-codegen gate must REFUSE these (SEAM §4 bans + not-yet-supported forms),
   raising Unsupported rather than silently miscompiling. *)
let rejects =
  [ "float f(float x){ return x; }", "f" (* float — SEAM §4 *)
  ; "long long g(long long x){ return x + 1; }", "g" (* 64-bit — SEAM §4 *)
  ; "int h(int a){ if (a) return 1; return 0; }", "h" (* control flow — later slice *)
  ; "int k(int *p){ return *p; }", "k" (* memory — later slice *)
  ; "int d(int a){ return a / 2; }", "d" (* / lowers to a call — SEAM §5 *)
  ]

let () =
  Random.init 0x51ce;
  let r32 () =
    let b () = Random.bits () in
    let x = (b () lor (b () lsl 15) lor (b () lsl 30)) land 0xFFFF_FFFF in
    if x >= 0x8000_0000 then x - 0x1_0000_0000 else x
  in
  let edges = [ 0; 1; -1; 2; -2; 7; 0x7FFF_FFFF; -0x8000_0000; 100000; -100000 ] in
  let nrand = 40 in
  let total = ref 0
  and fails = ref 0 in
  List.iter
    (fun (src, fname, arity) ->
      let body = our_compile ~src ~fname in
      let exe = gcc_compile ~src ~fname ~arity in
      let tuples =
        List.map (fun v -> List.init arity (fun _ -> v)) edges
        @ List.init nrand (fun _ -> List.init arity (fun _ -> r32 ()))
      in
      let sfails = ref 0 in
      List.iter
        (fun args ->
          incr total;
          let ours = u32 (Backend.Runner.run_leaf body args) in
          let refv = gcc_run exe args in
          if ours <> refv
          then begin
            incr fails;
            incr sfails;
            Printf.printf
              "  MISMATCH %s(%s): ours=%08x gcc=%08x\n"
              fname
              (String.concat "," (List.map string_of_int args))
              ours
              refv
          end)
        tuples;
      Sys.remove exe;
      Printf.printf
        "  %-7s %d instr, %d cases%s\n"
        fname
        (List.length body)
        (List.length tuples)
        (if !sfails = 0 then "  ok" else Printf.sprintf "  %d MISMATCH" !sfails))
    samples;
  List.iter
    (fun (src, fname) ->
      match our_compile ~src ~fname with
      | exception Backend.Codegen.Unsupported msg ->
        Printf.printf "  reject %-6s ✓ (%s)\n" fname msg
      | _ ->
        incr fails;
        Printf.printf "  reject %-6s ✗ — GATE LEAK: compiled a banned construct\n" fname)
    rejects;
  Printf.printf
    "diff jig: %d run cases across %d samples + %d gate rejects, %d failures\n"
    !total
    (List.length samples)
    (List.length rejects)
    !fails;
  if !fails > 0 then exit 1
