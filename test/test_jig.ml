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
  (* compile every function in the snippet; link with the entry [fname] first so it lands at
     offset 0 (where the Runner starts) and its callees follow *)
  let objs = List.map (Fundec.compile ~globals) (Frontend.fundecs file) in
  let entry, rest = List.partition (fun o -> o.Linker.name = fname) objs in
  (Linker.link (entry @ rest)).Linker.code, globals.Globals.image
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
  (* The oracle must model *our* target's data model, not the x86-64 host's:
     -m32: RISC5 is ILP32 (int/long/pointer all 32-bit), so on the host build them 32-bit too.
       Without it sizeof(ptr)/sizeof(long) are 8, not 4 — the jig flagged exactly this at sizeof.
     -funsigned-char: ABI §1 makes char unsigned (LDB zero-extends); the host default (signed)
       would sign-extend on widening reads and the diff would be apples-to-oranges.
     Both keep [int] 32-bit either way — the base case that made int-only samples agree. *)
  let cmd =
    Printf.sprintf
      "gcc -std=gnu99 -m32 -funsigned-char -w -O0 %s -o %s"
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
    (* s4.1b: calls — the caller marshals args into R0-R3 (via the home area) and BL's a
       named callee; the callee is non-leaf so its homes live in callee-saved R6-R11 and
       survive the call. The entry (fname) links first (offset 0); callees follow. *)
  ; "int g(int x){ return x + 1; } int f(int x){ return g(x) * 2; }", "f", 1
  ; ( "int add3(int a,int b,int c){ return a + b + c; } int u3(int x){ return add3(x, x \
       + 1, x + 2); }"
    , "u3"
    , 1 )
  ; ( "int add4(int a,int b,int c,int d){ return a + b + c + d; } int u4(int x){ return \
       add4(x, x + 1, x + 2, x + 3); }"
    , "u4"
    , 1 (* all four register args *) )
  ; ( "int sq(int x){ return x * x; } int ss(int x){ return sq(x) + sq(x + 1); }"
    , "ss"
    , 1 (* two calls; the first result is held (a home) across the second *) )
  ; ( "int inc(int x){ return x + 1; } int chain(int x){ int a = x * 3; int b = inc(a); \
       return a + b; }"
    , "chain"
    , 1 (* a is live across the call: its callee-saved home preserves it *) )
  ; ( "int fib(int n){ n &= 7; if (n < 2) return n; return fib(n - 1) + fib(n - 2); }"
    , "fib"
    , 1 (* recursion: each frame's n survives both self-calls; masked so it terminates *)
    )
    (* s4.2: a callee with >4 params reads args 5+ off the frame — FP = entry SP (ABI §3), so
       the Runner (caller) puts args 1-4 in R0-R3 and args 5+ on the stack at SP+16.., and the
       callee loads them from FP+16.. into their homes. *)
  ; ( "int sum6(int a,int b,int c,int d,int e,int f){ return a+b+c+d+e+f; }"
    , "sum6"
    , 6 (* leaf, 6 params: e,f arrive on the stack; leaf+FP frame *) )
  ; ( "int side(int x){ return x; } int nl5(int a,int b,int c,int d,int e){ return \
       side(a) + b + c + d + e; }"
    , "nl5"
    , 5
      (* non-leaf, 5 params: e on the stack, homes R6-R11, FP+LNK frame, a <=4-arg call *)
    )
    (* s4.2 step 2: a caller with >4 args stages args 5+ past the home area (SP+16..) and BLs;
       the callee reads them back at FP+16.. — a full round-trip through our own code, diffed
       vs gcc. u5: one stack arg (add5 leaf callee); u6: two stack args, position-weighted so a
       mis-ordered slot would show up. *)
  ; ( "int add5(int a,int b,int c,int d,int e){ return a+b+c+d+e; } int u5(int x){ \
       return add5(x, x+1, x+2, x+3, x+4); }"
    , "u5"
    , 1 (* 5-arg call: one stack arg at SP+16; add5 is a leaf+FP callee *) )
  ; ( "int take6(int a,int b,int c,int d,int e,int f){ return a + b*2 + c*3 + d*4 + e*5 \
       + f*6; } int u6(int x){ return take6(x, x+1, x+2, x+3, x+4, x+5); }"
    , "u6"
    , 1 (* 6-arg call: two stack args (SP+16, SP+20); outgoing area = 24 *) )
  ; ( "int add5(int a,int b,int c,int d,int e){ return a+b+c+d+e; } int both5(int a,int \
       b,int c,int d,int e){ return add5(e,d,c,b,a) + a; }"
    , "both5"
    , 5
      (* both mechanisms in one frame: reads its own stack param e (FP+16) AND passes a stack
         arg to add5 (SP+16) — incoming (above FP) and outgoing (near SP) areas are disjoint;
         the reversed arg order would surface a misplaced slot *)
    )
    (* s4.3 step 1: locals that can't be a register get an SP-relative frame slot — aggregates
       (array/struct) and address-taken scalars (CIL's vaddrof). Access, &, and pointer-writes
       all route through the s3.2 memory calculus based at the slot. State lives inside each
       sample; every slot is written before it's read (else our garbage != gcc's garbage). *)
  ; ( "int aql(int x){ int y = x; int *p = &y; *p = *p + 3; return y; }"
    , "aql"
    , 1 (* address-taken scalar: &y, and y aliases *p — the write lands in y's slot *) )
  ; ( "int larr(int i){ int t[4]; t[0]=5; t[1]=6; t[2]=7; t[3]=8; return t[i & 3]; }"
    , "larr"
    , 1 (* local array: const-index writes, dynamic-index read, all off the slot *) )
  ; ( "struct ls { int a; int b; }; int lstruct(int k){ struct ls p; p.a = k; p.b = k + \
       1; return p.a * p.b; }"
    , "lstruct"
    , 1 (* local struct: field writes/reads at slot+0 / slot+4 → k*(k+1) *) )
  ; ( "int cptr(int x){ char c = x; char *p = &c; *p = *p + 1; return c; }"
    , "cptr"
    , 1 (* sub-word slot: LDB/STB on the slot; result ((x&0xFF)+1)&0xFF *) )
  ; ( "int addone(int *p){ *p = *p + 1; return 0; } int outp(int x){ int y = x; \
       addone(&y); return y; }"
    , "outp"
    , 1 (* &local escaping to a callee (out-param): slot + outgoing area coexist → x+1 *)
    )
    (* s4.3 step 2: an address-taken *param* — vaddrof, like a local, but it arrives with a
       value. It keeps its register home (so leaf positional placement isn't disturbed) and the
       prologue spills that home into the slot; body access is the slot, as for a local. *)
  ; ( "int aptr(int x){ int *p = &x; *p = *p + 5; return x; }"
    , "aptr"
    , 1 (* address-taken scalar param: prologue spills R0 → slot; x aliases *p → x+5 *) )
  ; ( "int amid(int a,int b,int c){ int *p = &b; return a + *p * 10 + c * 100; }"
    , "amid"
    , 3
      (* the *middle* param is slotted: a,c keep their homes, b spills; b read via *p →
         a + b*10 + c*100, position-weighted so a disturbed placement would surface *)
    )
  ; ( "int addfive(int *p){ *p = *p + 5; return 0; } int outparam(int x){ addfive(&x); \
       return x; }"
    , "outparam"
    , 1 (* &param escaping to a callee (the real out-param pattern) → x+5 *) )
    (* s4.4: whole-struct copy (a = b) — the only by-value aggregate op in DOOM (census: 0
       struct args/returns, 16 copies). Byte-wise, so alignment-agnostic; each sample writes
       fields, copies the struct, then reads fields back to prove the bytes landed. *)
  ; ( "struct s2 { int a; int b; }; int cps(int x){ struct s2 p, q; p.a = x; p.b = x + \
       1; q = p; return q.a * 10 + q.b; }"
    , "cps"
    , 1 (* local struct copy, both slotted (s4.3): 8 B, word-aligned → 11x+1 *) )
  ; ( "struct s2 { int a; int b; }; int cpp(int x){ struct s2 p, q; struct s2 *sp = &p; \
       struct s2 *dp = &q; p.a = x; p.b = x + 3; *dp = *sp; return q.a * 2 + q.b; }"
    , "cpp"
    , 1 (* copy through pointers: *dp = *sp, both addresses via deref → 3x+3 *) )
  ; ( "struct sh { short x; short y; short z; }; int cpsh(int a){ struct sh p, q; p.x = \
       a; p.y = a + 1; p.z = a + 2; q = p; return q.x + q.y * 100 + q.z * 10000; }"
    , "cpsh"
    , 1
      (* the alignment case: 6 B, align 2 — byte-copy handles the non-word size and the
         sub-word address that LDW/STW would mask; short fields truncate on both sides *)
    )
  ; ( "struct s2 { int a; int b; }; int cparr(int i){ i &= 1; struct s2 arr[2]; arr[0].a \
       = 10; arr[0].b = 20; arr[1].a = 30; arr[1].b = 40; struct s2 t; t = arr[i]; \
       return t.a + t.b; }"
    , "cparr"
    , 1 (* indexed source: t = arr[i], the real array-copy pattern → 30 or 70 *) )
  ; ( "struct sc { int a; int b; }; struct sc s1 = {1, 2}; struct sc s2; int cpg(int x){ \
       s2 = s1; return s2.a + x; }"
    , "cpg"
    , 1 (* global struct copy: both sides DB-relative → 1 + x (was a reject pre-s4.4) *) )
    (* s5.1: a comparison or ! as a 0/1 *value* (not a branch) — materialized by branching over
       two immediate loads (no set-on-condition on RISC5). All six relops exercise the rel_cond
       (cond, neg) mapping; a flipped neg would invert the result, which the full-range args
       (incl. INT_MIN/MAX, where signed compare must still hold through SUB overflow) catch. *)
  ; "int ltv(int a,int b){ return a < b; }", "ltv", 2
  ; "int gtv(int a,int b){ return a > b; }", "gtv", 2
  ; "int lev(int a,int b){ return a <= b; }", "lev", 2
  ; "int gev(int a,int b){ return a >= b; }", "gev", 2
  ; "int eqv(int a,int b){ return a == b; }", "eqv", 2
  ; "int nev(int a,int b){ return a != b; }", "nev", 2
  ; "int lnot(int x){ return !x; }", "lnot", 1 (* !x = (x == 0) *)
  ; ( "int notnot(int x){ return !!x; }"
    , "notnot"
    , 1 (* boolean-normalize any nonzero → 1 *) )
  ; ( "int cmix(int a,int b){ return (a > b) * 100 + (a < b) * 10 + (a == b); }"
    , "cmix"
    , 2
      (* materialized bools as arithmetic operands; trichotomy → exactly 100, 10, or 1 *)
    )
    (* s5.2: unsigned ordered compares — same SUB + materialize/branch as s5.1, but the ordered
       ops read the *carry* (Cs = below, Ls = below-or-same) instead of the signed N≠V. The
       equal-pair edges can't tell signed from unsigned; the 40 full-range random tuples do, and
       uhi pins it deterministically (a < 2^31 is 1 for small a unsigned, 0 if wrongly signed —
       the a=1 edge catches that). *)
  ; "int ultv(unsigned a,unsigned b){ return a < b; }", "ultv", 2
  ; "int ulev(unsigned a,unsigned b){ return a <= b; }", "ulev", 2 (* Ls = C|Z *)
  ; "int ugtv(unsigned a,unsigned b){ return a > b; }", "ugtv", 2
  ; "int ugev(unsigned a,unsigned b){ return a >= b; }", "ugev", 2
  ; ( "int uhi(unsigned a){ return a < 0x80000000u; }"
    , "uhi"
    , 1
      (* deterministic signed/unsigned distinguisher: a=1 → 1 unsigned, 0 if wrongly signed *)
    )
  ; ( "int uc(unsigned a,unsigned b){ if (a < b) return 1; return 0; }"
    , "uc"
    , 2 (* unsigned compare as a *condition* (gen_cond path); was a reject pre-s5.2 *) )
  ; ( "int pcmp(int i,int j){ int a[8]; int *p = &a[i & 7]; int *q = &a[j & 7]; return p \
       < q; }"
    , "pcmp"
    , 2
      (* pointer < (CIL lowers to unsigned; the pointer-walk payoff): both point into one local
         array, so p < q iff (i&7) < (j&7) — jig-safe, only the 0/1 escapes *)
    )
    (* s5.2b: unsigned (logical) >> — ROR then mask, since RISC5 has no LSR. The edge x=-1
       (0xFFFFFFFF) separates logical from arithmetic: >>1 is 0x7FFFFFFF (logical) vs 0xFFFFFFFF
       (ASR). Spans the mask cases: n=1 needs a load_const mask (0x7FFFFFFF > 16-bit imm), n=16
       fits an immediate (0xFFFF), n=31 is a 1-bit mask. *)
  ; "unsigned usr1(unsigned x){ return x >> 1; }", "usr1", 1
  ; "unsigned usr16(unsigned x){ return x >> 16; }", "usr16", 1 (* FRACBITS-shaped *)
  ; "unsigned usr31(unsigned x){ return x >> 31; }", "usr31", 1 (* sign bit as 0/1 *)
  ; ( "unsigned usrmix(unsigned a){ return (a >> 8) & 0xFF; }"
    , "usrmix"
    , 1 (* the real byte-extract idiom: logical >> feeding a mask *) )
    (* s5.3: switch — dispatch chain (compare vs each case, branch to its label), fall-through
       as natural statement order, break exits, default catches the rest. x is masked so the
       full-range args land on real cases / the default. *)
  ; ( "int sw1(int x){ x &= 3; int r = 0; switch (x) { case 0: r = 10; break; case 1: r \
       = 20; break; case 2: r = 30; break; default: r = 99; } return r; }"
    , "sw1"
    , 1 (* one case each + default → 10 / 20 / 30 / 99 *) )
  ; ( "int swf(int x){ x &= 3; int r = 0; switch (x) { case 0: r += 1; case 1: r += 10; \
       case 2: r += 100; break; default: r = 999; } return r; }"
    , "swf"
    , 1 (* fall-through (no break between cases): 111 / 110 / 100 / 999 *) )
  ; ( "int swd(int x){ x &= 7; switch (x) { case 1: case 2: return 12; case 5: return 5; \
       default: return 0; } }"
    , "swd"
    , 1 (* shared case labels + return inside the switch → 12 / 5 / 0 *) )
  ; ( "int swnb(int x){ x &= 3; int r = 7; switch (x) { case 1: r = 100; break; case 2: \
       r = 200; break; } return r; }"
    , "swnb"
    , 1 (* no default: unmatched values fall straight past to break → 7 *) )
    (* s5.4: continue + goto, both jumps to a labeled statement (the s5.3 label map). CIL keeps
       a while/do continue as C.Continue (→ loop top); it lowered the for-loop continue to a goto
       before the increment; goto itself is forward or backward to any labeled statement. *)
  ; ( "int wc(int n){ n &= 15; int s = 0, i = 0; while (i < n) { i++; if (i == 3) \
       continue; s += i; } return s; }"
    , "wc"
    , 1 (* while continue (→ loop top): sum 1..n except 3 *) )
  ; ( "int fc(int n){ n &= 7; int s = 0, i = 0; for (i = 0; i < n; i++) { if (i == 2) \
       continue; s += i; } return s; }"
    , "fc"
    , 1 (* for continue: CIL lowered it to a goto before i++ → sum 0..n-1 except 2 *) )
  ; ( "int gt(int x){ int s = 0; if (x < 0) goto done; s = x * 2; done: return s + 1; }"
    , "gt"
    , 1 (* forward goto skipping code → (x<0 ? 0 : 2x) + 1 *) )
  ; ( "int gtb(int n){ n &= 7; int s = 0, i = 0; top: if (i < n) { s += i; i++; goto \
       top; } return s; }"
    , "gtb"
    , 1 (* backward goto = a hand-rolled loop → sum 0..n-1 *) )
    (* spilling (§4 rung 1): a non-leaf with >6 register variables — the first 6 take the
       callee-saved homes R6-R11, the rest spill to frame slots. The values are computed before
       a call and read after, so each must survive it (a home is callee-saved, a slot is memory —
       both do); the result folds all of them in, so a dropped or aliased spill shows in R0. Each
       sample inlines its callee so the whole source is one translation unit (both sides). *)
  ; ( "int addc(int x, int y){ return x + y; } int many(int a, int b){ int t0 = a, t1 = \
       a + b, t2 = a - b, t3 = a * 2, t4 = b * 2, t5 = a + 1, t6 = b + 1, t7 = a ^ b, t8 \
       = a & b, t9 = a | b; int s = addc(t0, t1); return s + t2 + t3 + t4 + t5 + t6 + t7 \
       + t8 + t9; }"
    , "many"
    , 2 (* 2 params + 11 locals = 13 reg vars → 7 spill; all live across addc *) )
  ; ( "int idc(int x){ return x; } int sloop(int n){ n &= 7; int a = 1, b = 2, c = 3, d \
       = 4, e = 5, f = 6, g = 7, h = 8; int i = 0, s = 0; for (i = 0; i < n; i++){ s += \
       idc(a + b + c + d + e + f + g + h) + i; } return s; }"
    , "sloop"
    , 1 (* spilled locals live across a call *inside a loop* → n*36 + sum(0..n-1) *) )
  ; ( "int rd(int *p){ return *p; } int mixs(int a, int b){ int box = a * 3; int t0 = a, \
       t1 = b, t2 = a + b, t3 = a - b, t4 = a | b, t5 = a & b, t6 = a ^ b, t7 = a + 1; \
       int s = rd(&box); return s + t0 + t1 + t2 + t3 + t4 + t5 + t6 + t7; }"
    , "mixs"
    , 2
      (* an address-taken slot (box, s4.3) and spilled-local slots share the locals region *)
    )
    (* sizeof folds to a compile-time constant (size_t). Each result folds in [x] so the varying
       arg confirms the fold is a real value, not a fluke; the host returns [int], so its 64-bit
       size_t truncates to the same 32 bits we compute. Covers SizeOf(scalar/pointer/struct
       type), SizeOfE (sizeof of an *expression* — an array lvalue), and SizeOfStr. *)
  ; "int szint(int x){ return sizeof(int) + x; }", "szint", 1 (* SizeOf: 4 + x *)
  ; ( "int szptr(int x){ return sizeof(int *) + x; }"
    , "szptr"
    , 1 (* pointer is 4 B (ABI §1): 4 + x *) )
  ; ( "struct pt3 { int a; int b; }; int szst(int x){ return sizeof(struct pt3) + x; }"
    , "szst"
    , 1 (* SizeOf an aggregate type: 8 + x *) )
  ; ( "int szarr(int x){ int a[10]; return sizeof(a) + x; }"
    , "szarr"
    , 1 (* SizeOfE: sizeof of an array lvalue, operand unevaluated → 40 + x *) )
  ; ( "int szstr(int x){ return sizeof(\"hello\") + x; }"
    , "szstr"
    , 1 (* SizeOfStr: 5 bytes + NUL → 6 + x *) )
  ]
;;

(* The pre-codegen gate must REFUSE these (ABI §4 bans + not-yet-supported forms),
   raising Unsupported rather than silently miscompiling. Note `int k(int *p){ return *p; }`
   COMPILES as of s3.2a but can't run here — the harness passes ints, and a random int is
   not a valid pointer on either side; deref coverage comes from drf/arrow above. *)
let rejects =
  [ "float f(float x){ return x; }", "f" (* float — ABI §4 *)
  ; "long long g(long long x){ return x + 1; }", "g" (* 64-bit — ABI §4 *)
  ; ( "int callptr(int (*fp)(int), int x){ return fp(x); }"
    , "callptr" (* indirect call (function pointer) — later slice *) )
  ; ( "struct pt { int x; int y; }; extern struct pt mk(int); int usemk(int x){ struct \
       pt p = mk(x); return p.x; }"
    , "usemk" (* aggregate return by value — none in DOOM (census); deferred *) )
  ; ( "struct s3 { int a; int b; int c; }; struct s3 sa[4]; int ppd(int i){ struct s3 *p \
       = sa + (i & 3); struct s3 *q = sa; return p - q; }"
    , "ppd" (* ptr−ptr, 12-byte elem: non-pow-2 → needs __div *) )
  ; ( "char *msg = \"hi\"; int sl(int x){ if (msg) return x; return 1; }"
    , "sl" (* string-literal init — 3b linker *) )
  ; ( "extern int ext; int rex(int x){ return ext + x; }"
    , "rex" (* declared, never defined — 3b linker *) )
  ; "int d(int a){ return a / 2; }", "d" (* / lowers to a call — ABI §5 *)
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
