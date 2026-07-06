(* Differential jig (AGENT.md §7/§9): compile small C leaves with OUR backend, run them in the
   emulator, and diff R0 against host gcc over edge + random int args. gcc's [int] is 32-bit on
   x86-64, matching RISC5, so int-only samples must agree bit-for-bit.

   This is the harness the backend grows against: each new codegen feature adds a sample and is
   trusted only once it matches gcc here. Covers straight-line integer ops and if/while/for
   control flow; loop samples mask their trip count so the full-range args below can't spin.
   Parse+codegen and gcc-compile both happen once per sample; only the (fast) runs repeat per
   arg-tuple. *)

let u32 x = x land 0xFFFF_FFFF

(* ---- doomcc side: parse -> codegen (once per sample) ---- *)
let dcc_compile ~src ~fname =
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

(* ---- samples: each is (source, name, arity); every construct below is supported ---- *)
let samples =
  [ (* straight-line integer ops *)
    "int add(int a,int b){ return a+b; }", "add", 2
  ; "int sub(int a,int b){ return a-b; }", "sub", 2
  ; "int mul(int a,int b){ return a*b; }", "mul", 2
  ; "int bitops(int a,int b){ return (a & b) | (a ^ b); }", "bitops", 2
  ; "int shl(int a){ return a << 3; }", "shl", 1
  ; "int sar(int a){ return a >> 1; }", "sar", 1 (* signed: arithmetic shift right *)
  ; "int mix(int a,int b,int c){ int t = a*b; return t - c + 7; }", "mix", 3
  ; "int bigc(int a){ return a + 100000; }", "bigc", 1 (* exercises the 32-bit load_const *)
  ; "int negx(int a){ return -a; }", "negx", 1
  ; "int notx(int a){ return ~a; }", "notx", 1
    (* control flow: truthiness / signed compares / else-if / multiple returns / && (nested if) *)
  ; "int truthy(int a){ if (a) return 1; return 0; }", "truthy", 1
  ; "int imax(int a,int b){ if (a > b) return a; return b; }", "imax", 2
  ; "int iabs(int a){ if (a < 0) return -a; return a; }", "iabs", 1
  ; "int sgn(int a){ if (a < 0) return -1; if (a > 0) return 1; return 0; }", "sgn", 1
  ; "int clamp(int a){ if (a < 0) a = 0; else if (a > 127) a = 127; return a; }", "clamp", 1
  ; "int eqs(int a,int b){ if (a == b) return 111; if (a != b) return 222; return 0; }", "eqs", 2
  ; "int both(int a,int b){ if (a > 0 && b > 0) return a + b; return 0; }", "both", 2
    (* loops: trip count masked small so full-range args terminate *)
  ; "int tri(int n){ n &= 15; int s = 0; while (n > 0){ s += n; n--; } return s; }", "tri", 1
  ; "int po2(int k){ k &= 7; int r = 1; int i = 0; for (i = 0; i < k; i++){ r = r * 2; } return r; }", "po2", 1
  ; "int loopsum(int a,int b){ b &= 7; int s = a; int i = 0; for (i = 0; i < b; i++) s = s + a; return s; }", "loopsum", 2
  ]

(* The pre-codegen gate must REFUSE these (ABI §4 bans + not-yet-supported forms),
   raising Unsupported rather than silently miscompiling. *)
let rejects =
  [ "float f(float x){ return x; }", "f" (* float — ABI §4 *)
  ; "long long g(long long x){ return x + 1; }", "g" (* 64-bit — ABI §4 *)
  ; "int k(int *p){ return *p; }", "k" (* memory — later slice *)
  ; "int d(int a){ return a / 2; }", "d" (* / lowers to a call — ABI §5 *)
  ; "int cv(int a,int b){ return a < b; }", "cv" (* compare as a value — later slice *)
  ; "int uc(unsigned a,unsigned b){ if (a < b) return 1; return 0; }", "uc" (* unsigned ordered — later *)
  ; "int cn(int n){ n&=7; int s=0,i=0; for(i=0;i<n;i++){ if(i==2) continue; s+=i; } return s; }", "cn" (* continue → CIL lowers it to a goto — later *)
  ]

(* a random 32-bit signed arg, plus the edge values every sample is probed with *)
let r32 () =
  let b () = Random.bits () in
  let x = (b () lor (b () lsl 15) lor (b () lsl 30)) land 0xFFFF_FFFF in
  if x >= 0x8000_0000 then x - 0x1_0000_0000 else x

let edges = [ 0; 1; -1; 2; -2; 7; 0x7FFF_FFFF; -0x8000_0000; 100000; -100000 ]
let nrand = 40

(* one sample: compile with both backends, diff R0 over edge + random arg-tuples;
   returns (run cases, mismatches) for the caller to total up *)
let check_sample (src, fname, arity) : int * int =
  let body = dcc_compile ~src ~fname in
  let exe = gcc_compile ~src ~fname ~arity in
  let tuples =
    List.map (fun v -> List.init arity (fun _ -> v)) edges
    @ List.init nrand (fun _ -> List.init arity (fun _ -> r32 ()))
  in
  let sfails = ref 0 in
  List.iter
    (fun args ->
      let ours = u32 (Backend.Runner.run_leaf body args) in
      let refv = gcc_run exe args in
      if ours <> refv
      then begin
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
    (if !sfails = 0 then "  ok" else Printf.sprintf "  %d MISMATCH" !sfails);
  List.length tuples, !sfails

(* one reject: the gate must raise Unsupported rather than miscompile; returns 1 if it leaked *)
let check_reject (src, fname) : int =
  match dcc_compile ~src ~fname with
  | exception Backend.Codegen.Unsupported msg ->
    Printf.printf "  reject %-6s ✓ (%s)\n" fname msg;
    0
  | _ ->
    Printf.printf "  reject %-6s ✗ — GATE LEAK: compiled a banned construct\n" fname;
    1

let () =
  Random.init 0x51ce;
  let total, sample_fails =
    List.fold_left
      (fun (cases, fails) sample ->
        let c, f = check_sample sample in
        cases + c, fails + f)
      (0, 0)
      samples
  in
  let fails = sample_fails + List.fold_left (fun acc r -> acc + check_reject r) 0 rejects in
  Printf.printf
    "diff jig: %d run cases across %d samples + %d gate rejects, %d failures\n"
    total
    (List.length samples)
    (List.length rejects)
    fails;
  if fails > 0 then exit 1
