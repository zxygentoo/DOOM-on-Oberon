(* Differential jig (AGENT.md §7/§9): compile small C leaves with OUR backend, run them in the
   emulator, and diff R0 against host gcc over edge + random int args. gcc's [int] is 32-bit on
   x86-64, matching RISC5, so int-only samples must agree bit-for-bit.

   This is the harness the backend grows against: each new codegen feature adds a sample and is
   trusted only once it matches gcc here. Covers straight-line integer ops, if/while/for
   control flow, and memory — globals, arrays, structs, deref (memory lives *inside* the
   samples, so the harness stays int-in/int-out; both sides get fresh global state per run —
   ours by rewriting the data image, gcc's by a fresh process).

   Sample-authorship rules: (1) loop samples mask their trip count so the full-range args
   below can't spin; (2) NEVER let a raw pointer value reach a result or comparison — the
   emulator and the host live in different address spaces (DB = 0x80000 vs wherever gcc's
   data lands), so only *dereferenced values* and *pointer differences* are comparable.
   Parse+compile and gcc-compile both happen once per sample; only the (fast) runs repeat
   per arg-tuple. *)

open Doomcc_core

let u32 x = x land 0xFFFF_FFFF

(* ---- doomcc side: parse -> place globals -> compile (once per sample); returns the
   body plus the data/bss image the runner drops at DB before each run ---- *)
let dcc_compile ~src ~fname =
  let file = Frontend.parse_string ~name:fname src in
  let globals = Globals.from_file file in
  let fd = Frontend.find_fundec file fname in
  let obj = Fundec.compile ~globals fd in
  (Linker.link [ obj ]).Linker.code, globals.Globals.image
;;

(* ---- gcc oracle: compile [src] + a tiny argv driver once, then run the exe per tuple ---- *)
let gcc_compile ~src ~fname ~arity : string =
  let cfile = Filename.temp_file "jig" ".c" in
  let exe = cfile ^ ".exe" in
  let oc = open_out cfile in
  output_string oc src;
  output_string oc "\n#include <stdio.h>\n#include <stdlib.h>\n";
  let params =
    List.init arity (fun i -> Printf.sprintf "(int)strtol(argv[%d],0,10)" (i + 1))
  in
  Printf.fprintf
    oc
    "int main(int argc,char**argv){(void)argc;printf(\"%%d\\n\",%s(%s));return 0;}\n"
    fname
    (String.concat "," params);
  close_out oc;
  (* -funsigned-char: the oracle must model *our* target, and ABI §1 makes char unsigned
     (LDB zero-extends). Without it gcc's x86-64 default (signed char) sign-extends on
     widening reads and the diff is apples-to-oranges — the jig flagged exactly this. *)
  let cmd =
    Printf.sprintf
      "gcc -std=gnu99 -funsigned-char -w -O0 %s -o %s"
      (Filename.quote cfile)
      (Filename.quote exe)
  in
  if Sys.command cmd <> 0 then failwith ("gcc failed for " ^ fname);
  Sys.remove cfile;
  exe
;;

let gcc_run exe (args : int list) : int =
  let cmd =
    Printf.sprintf
      "%s %s"
      (Filename.quote exe)
      (String.concat " " (List.map string_of_int args))
  in
  let ic = Unix.open_process_in cmd in
  let line =
    try input_line ic with
    | End_of_file -> ""
  in
  ignore (Unix.close_process_in ic);
  u32 (int_of_string (String.trim line))
;;

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
  ; ( "int bigc(int a){ return a + 100000; }"
    , "bigc"
    , 1 (* exercises the 32-bit load_const *) )
  ; "int negx(int a){ return -a; }", "negx", 1
  ; "int notx(int a){ return ~a; }", "notx", 1
    (* control flow: truthiness / signed compares / else-if / multiple returns / && (nested if) *)
  ; "int truthy(int a){ if (a) return 1; return 0; }", "truthy", 1
  ; "int imax(int a,int b){ if (a > b) return a; return b; }", "imax", 2
  ; "int iabs(int a){ if (a < 0) return -a; return a; }", "iabs", 1
  ; "int sgn(int a){ if (a < 0) return -1; if (a > 0) return 1; return 0; }", "sgn", 1
  ; ( "int clamp(int a){ if (a < 0) a = 0; else if (a > 127) a = 127; return a; }"
    , "clamp"
    , 1 )
  ; ( "int eqs(int a,int b){ if (a == b) return 111; if (a != b) return 222; return 0; }"
    , "eqs"
    , 2 )
  ; "int both(int a,int b){ if (a > 0 && b > 0) return a + b; return 0; }", "both", 2
    (* loops: trip count masked small so full-range args terminate *)
  ; ( "int tri(int n){ n &= 15; int s = 0; while (n > 0){ s += n; n--; } return s; }"
    , "tri"
    , 1 )
  ; ( "int po2(int k){ k &= 7; int r = 1; int i = 0; for (i = 0; i < k; i++){ r = r * 2; \
       } return r; }"
    , "po2"
    , 1 )
  ; ( "int loopsum(int a,int b){ b &= 7; int s = a; int i = 0; for (i = 0; i < b; i++) s \
       = s + a; return s; }"
    , "loopsum"
    , 2 )
    (* globals (s3.1): DB-relative scalar LDW/STW; state is fresh per run on both sides *)
  ; "int gi = 42; int grd(int x){ return gi + x; }", "grd", 1
  ; ( "int gz; int rz(int x){ return gz + x; }"
    , "rz"
    , 1 (* no init: the zero-filled (bss) half *) )
  ; ( "int gw; int gwr(int x){ gw = x * 2; return gw + 1; }"
    , "gwr"
    , 1 (* store, then load back *) )
  ; ( "int g0 = 3; int g1 = 5; int g2 = -7; int sumg(int x){ return g0 + g1 * x + g2; }"
    , "sumg"
    , 1 )
  ; ( "int s0 = 11; int s1 = 22; int swp(int x){ int t = s0; s0 = s1; s1 = t + x; return \
       s0 * 1000 + s1; }"
    , "swp"
    , 1 )
  ; ( "static int acc = 5; int gacc(int n){ n &= 7; int i = 0; for (i = 0; i < n; i++){ \
       acc = acc + i; } return acc; }"
    , "gacc"
    , 1 )
    (* address calculus (s3.2a): arrays / structs / deref — see the pointer rule above *)
  ; "int a1[8] = {3,1,4,1,5,9,2,6}; int geti(int i){ return a1[i & 7]; }", "geti", 1
  ; ( "int a2[8] = {3,1,4,1,5,9,2,6}; int getc3(int x){ return a2[3] + x; }"
    , "getc3"
    , 1 (* const index folds to one LDW *) )
  ; ( "int a3[8]; int setg(int i,int v){ a3[i & 7] = v; return a3[i & 7] + a3[(i + 1) & \
       7]; }"
    , "setg"
    , 2 )
  ; ( "int za[4] = {10, 20}; int zpart(int i){ return za[i & 3]; }"
    , "zpart"
    , 1 (* partial init zero-fills *) )
  ; ( "int m[4][4] = {{1,2,3,4},{5,6,7,8},{9,10,11,12},{13,14,15,16}}; int mij(int i,int \
       j){ return m[i & 3][j & 3]; }"
    , "mij"
    , 2 )
  ; ( "int mm[4][4] = {{1,2,3,4},{5,6,7,8},{9,10,11,12},{13,14,15,16}}; int rowsum(int \
       r){ r &= 3; int s = 0; int j = 0; for (j = 0; j < 4; j++) s += mm[r][j]; return \
       s; }"
    , "rowsum"
    , 1 )
  ; ( "struct pt { int x; int y; }; struct pt p0 = {7, 11}; int gety(int k){ return p0.y \
       * k + p0.x; }"
    , "gety"
    , 1 )
  ; ( "struct in { int a; int b; }; struct outer { int c; struct in i; }; struct outer \
       o0 = {1, {2, 3}}; int nest(int k){ return o0.i.b + o0.c * k; }"
    , "nest"
    , 1 )
  ; "int gv = 5; int drf(int i){ int *q = &gv; return *q + i; }", "drf", 1
  ; ( "struct pt2 { int x; int y; }; struct pt2 pp = {20, 30}; int arrow(int k){ struct \
       pt2 *q = &pp; return q->x + q->y * k; }"
    , "arrow"
    , 1 )
    (* pointer arithmetic (s3.2b): ptr±int scaled, ptr−ptr; results derefed or differenced *)
  ; ( "int a4[8] = {2,4,6,8,10,12,14,16}; int pa(int i){ int *q = a4 + (i & 7); return \
       *q; }"
    , "pa"
    , 1 )
  ; ( "int ae[8] = {2,4,6,8,10,12,14,16}; int pm(int i){ int *q = ae + 7; return *(q - \
       (i & 7)); }"
    , "pm"
    , 1 (* MinusPI, dynamic *) )
  ; ( "int ad[8]; int pd(int i){ int *p = ad + (i & 7); int *q = ad + 2; return p - q; }"
    , "pd"
    , 1 (* ptr−ptr → count, pow-2 ASR *) )
  ; ( "int aw[8] = {1,2,3,4,5,6,7,8}; int wsum(int n){ n &= 7; int *q = aw; int s = 0; \
       int i = 0; for (i = 0; i < n; i++){ s += *q; q = q + 1; } return s; }"
    , "wsum"
    , 1 (* q = q+1 folds to ADD imm *) )
  ; ( "int af[8] = {1,2,3,4,5,6,7,8}; int walkne(int n){ n &= 7; int *q = af; int *end = \
       af + n; int s = 0; while (q != end){ s += *q; q = q + 1; } return s; }"
    , "walkne"
    , 1 (* walk to a sentinel: ptr != is sign-agnostic (ordered ptr < waits for s5) *) )
    (* sub-word char (s3.3a): LDB/STB, entry + cast narrowing; state lives inside samples *)
  ; "char gc = 65; int rgc(int x){ return gc + x; }", "rgc", 1
  ; ( "char ca[8] = {10,20,30,40,50,60,70,80}; int cget(int i){ return ca[i & 7]; }"
    , "cget"
    , 1 )
  ; ( "char cw[8]; int cset(int i,int v){ cw[i & 7] = v; return cw[i & 7]; }"
    , "cset"
    , 2 (* STB truncates → v & 0xFF *) )
  ; ( "int gw2 = 0x11223344; int cb(int i){ char *c = (char *)&gw2; return c[i & 3]; }"
    , "cb"
    , 1 (* little-endian byte order *) )
  ; "int pc(char c){ return c; }", "pc", 1 (* entry narrowing: c = arg & 0xFF *)
  ; ( "int cl(int x){ char c = x; c = c + 200; return c; }"
    , "cl"
    , 1 (* char local wraps at 256 *) )
  ; ( "struct m { int a; char b; }; struct m mm = {1000, 50}; int mf(int k){ return mm.a \
       + mm.b * k; }"
    , "mf"
    , 1 )
    (* sub-word short / signed char (s3.3b): halfword composed from 2×LDB/STB, and the
       signed vs unsigned widening that rides each load / cast / param entry *)
  ; "short gs = 1000; int rs(int x){ return gs + x; }", "rs", 1 (* signed short load *)
  ; ( "short gn = -5; int rn(int x){ return gn + x; }"
    , "rn"
    , 1 (* negative: sign-extend on the composed load *) )
  ; ( "unsigned short us = 50000; int ru(int x){ return us + x; }"
    , "ru"
    , 1 (* > 32767: zero-extended, NOT sign-extended *) )
  ; ( "signed char sc = -1; int rsc(int x){ return sc + x; }"
    , "rsc"
    , 1 (* LDB + sign-extend *) )
  ; ( "short sar[4] = {100,-200,300,-400}; int sget(int i){ return sar[i & 3]; }"
    , "sget"
    , 1 (* short array: element stride 2, mixed signs *) )
  ; ( "struct sm { int a; short b; }; struct sm sm0 = {1000, -50}; int smf(int k){ \
       return sm0.a + sm0.b * k; }"
    , "smf"
    , 1 (* signed short field at offset 4 *) )
  ; ( "short sw; int sset(int x){ sw = x; return sw; }"
    , "sset"
    , 1 (* composed store (2×STB) then signed read-back: (short)40000 = -25536 *) )
  ; ( "unsigned short uw; int uset(int x){ uw = x; return uw; }"
    , "uset"
    , 1 (* unsigned read-back: (unsigned short)70000 = 4464 *) )
  ; "int ps(short s){ return s; }", "ps", 1 (* signed short param: sign-extend at entry *)
  ; "int psc(signed char c){ return c; }", "psc", 1 (* signed char param entry narrow *)
  ; ( "int scast(int x){ short s = x; return s; }"
    , "scast"
    , 1 (* (short) narrowing cast as a value: gen_narrow signed path *) )
    (* s4.1a: the callee frame — enough live values to reach callee-saved R6-R9, so the
       prologue/epilogue save+restore them; the Runner's sentinel check (R6-R11 preserved,
       SP balanced) verifies the frame that a bare R0-result comparison can't yet see. *)
  ; ( "int regpress(int x){ int a=x+1,b=x+2,c=x+3,d=x+4,e=x+5,f=x+6; return a*b + c*d + \
       e*f + a - f; }"
    , "regpress"
    , 1 )
  ]
;;

(* The pre-codegen gate must REFUSE these (ABI §4 bans + not-yet-supported forms),
   raising Unsupported rather than silently miscompiling. Note `int k(int *p){ return *p; }`
   COMPILES as of s3.2a but can't run here — the harness passes ints, and a random int is
   not a valid pointer on either side; deref coverage comes from drf/arrow above. *)
let rejects =
  [ "float f(float x){ return x; }", "f" (* float — ABI §4 *)
  ; "long long g(long long x){ return x + 1; }", "g" (* 64-bit — ABI §4 *)
  ; ( "int la(int i){ int t[4]; t[0] = i; return t[0]; }"
    , "la" (* local array — needs a stack slot, call slice *) )
  ; ( "struct sc { int a; int b; }; struct sc s1 = {1,2}; struct sc s2; int cp(int x){ \
       s2 = s1; return s2.a + x; }"
    , "cp" (* struct copy — later *) )
  ; ( "struct s3 { int a; int b; int c; }; struct s3 sa[4]; int ppd(int i){ struct s3 *p \
       = sa + (i & 3); struct s3 *q = sa; return p - q; }"
    , "ppd" (* ptr−ptr, 12-byte elem: non-pow-2 → needs __div *) )
  ; ( "char *msg = \"hi\"; int sl(int x){ if (msg) return x; return 1; }"
    , "sl" (* string-literal init — 3b linker *) )
  ; ( "extern int ext; int rex(int x){ return ext + x; }"
    , "rex" (* declared, never defined — 3b linker *) )
  ; ( "int al(int x){ int y = x; int *p = &y; return x; }"
    , "al" (* &local needs a stack slot — call slice *) )
  ; "int d(int a){ return a / 2; }", "d" (* / lowers to a call — ABI §5 *)
  ; "int cv(int a,int b){ return a < b; }", "cv" (* compare as a value — later slice *)
  ; ( "int uc(unsigned a,unsigned b){ if (a < b) return 1; return 0; }"
    , "uc" (* unsigned ordered — later *) )
  ; ( "int cn(int n){ n&=7; int s=0,i=0; for(i=0;i<n;i++){ if(i==2) continue; s+=i; } \
       return s; }"
    , "cn" (* continue → CIL lowers it to a goto — later *) )
  ]
;;

(* a random 32-bit signed arg, plus the edge values every sample is probed with *)
let r32 () =
  let b () = Random.bits () in
  let x = b () lor (b () lsl 15) lor (b () lsl 30) land 0xFFFF_FFFF in
  if x >= 0x8000_0000 then x - 0x1_0000_0000 else x
;;

let edges = [ 0; 1; -1; 2; -2; 7; 0x7FFF_FFFF; -0x8000_0000; 100000; -100000 ]
let nrand = 40

(* one sample: compile with both backends, diff R0 over edge + random arg-tuples;
   returns (run cases, mismatches) for the caller to total up *)
let check_sample (src, fname, arity) : int * int =
  let body, data = dcc_compile ~src ~fname in
  let exe = gcc_compile ~src ~fname ~arity in
  let tuples =
    List.map (fun v -> List.init arity (fun _ -> v)) edges
    @ List.init nrand (fun _ -> List.init arity (fun _ -> r32 ()))
  in
  let sfails = ref 0 in
  List.iter
    (fun args ->
       let ours = u32 (Runner.run ~data body args) in
       let refv = gcc_run exe args in
       if ours <> refv
       then (
         incr sfails;
         Printf.printf
           "  MISMATCH %s(%s): ours=%08x gcc=%08x\n"
           fname
           (String.concat "," (List.map string_of_int args))
           ours
           refv))
    tuples;
  Sys.remove exe;
  Printf.printf
    "  %-7s %d instr, %d cases%s\n"
    fname
    (List.length body)
    (List.length tuples)
    (if !sfails = 0 then "  ok" else Printf.sprintf "  %d MISMATCH" !sfails);
  List.length tuples, !sfails
;;

(* one reject: the gate must raise Unsupported rather than miscompile; returns 1 if it leaked *)
let check_reject (src, fname) : int =
  match dcc_compile ~src ~fname with
  | exception Check.Unsupported msg ->
    Printf.printf "  reject %-6s ✓ (%s)\n" fname msg;
    0
  | _ ->
    Printf.printf "  reject %-6s ✗ — GATE LEAK: compiled a banned construct\n" fname;
    1
;;

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
  let fails =
    sample_fails + List.fold_left (fun acc r -> acc + check_reject r) 0 rejects
  in
  Printf.printf
    "diff jig: %d run cases across %d samples + %d gate rejects, %d failures\n"
    total
    (List.length samples)
    (List.length rejects)
    fails;
  if fails > 0 then exit 1
;;
