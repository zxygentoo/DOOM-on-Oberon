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

(* the mini-libc (1c): merged with a sample the way doomcc merges it with the DOOM
   tree. Parsed fresh per sample (Mergecil renames statics in its inputs); the gcc
   oracle side never sees it — our memcpy diffs against the REAL glibc. The path chain
   covers dune's two working directories (repo root for exec, test/ for runtest). *)
let libc_path name =
  List.find Sys.file_exists [ "libc/" ^ name; "../libc/" ^ name; "../../libc/" ^ name ]
;;

(* The jig-side fakes: the blob entries Init/Tick call doomgeneric_Create/Tick,
   which the real tree defines but the jig's libc-only merge does not — two no-op
   stand-ins keep the link whole and make the REAL entries runnable in the
   emulator (doomcc never sees these; it links the real doomgeneric.c). The fake
   Create deliberately does NOT call DG_Init: its banner printf would spin on the
   UART tx-ready bit the bare jig emulator never raises. *)
let port_fakes =
  "void doomgeneric_Tick(void) { } void doomgeneric_Create(int argc, char **argv) { \
   (void)argc; (void)argv; }"
;;

(* ---- doomcc side: parse -> place globals -> compile (once per sample); returns the
   body plus the data/bss image the runner drops at DB before each run ---- *)
let dcc_compile ?(libc = false) ?(port = false) ~src ~fname () =
  let file = Frontend.parse_string ~name:fname src in
  let file =
    if libc
    then
      Frontend.merge
        ([ file
         ; Frontend.parse_file (libc_path "mini.c")
         ; Frontend.parse_file (libc_path "stdio.c")
         ; Frontend.parse_file (libc_path "fixed.c")
         ]
         (* the platform layer only on request: its functions read [__shared_base],
            colors[] &c., which every merged sample would then have to define *)
         @
         if port
         then
           [ Frontend.parse_file (libc_path "doomgeneric_oberon.c")
           ; Frontend.parse_file (libc_path "dither.c")
           ; Frontend.parse_string ~name:"port_fakes" port_fakes
           ]
         else [])
        ~name:fname
    else file
  in
  let globals = Globals.from_file file in
  (* compile every function in the snippet; link with the entry [fname] first so it lands at
     offset 0 (where the Runner starts) and its callees follow — including the Runtime
     helpers (ABI §5: __div &c.), linked into every program exactly as the real blob will *)
  let objs = List.map (Fundec.compile ~globals) (Frontend.fundecs file) in
  let entry, rest = List.partition (fun o -> o.Linker.name = fname) objs in
  let image =
    Linker.link ~code_base:(Runner.code_base * 4) (entry @ rest @ Runtime.objs)
  in
  (* play loader for the pointer-initializer relocs (ABI §6): with both bases now fixed,
     each slot becomes an absolute address — data base + offset for a Data target, the
     linked function address (sym_addr) for a Code target (fn-ptr initializers, 3b.1) *)
  List.iter
    (fun (off, target) ->
       let v =
         match target with
         | Globals.Data t -> Runner.data_base + t
         | Globals.Code name -> Linker.sym_addr image name
       in
       Bytes.set_int32_le globals.Globals.image off (Int32.of_int v))
    globals.Globals.relocs;
  image.Linker.code, globals.Globals.image
;;

(* ---- gcc oracle: compile [src] + a tiny argv driver once, then run the exe per tuple ---- *)
let gcc_compile ?(gcc_extra = "") ~src ~fname ~arity () : string =
  let cfile = Filename.temp_file "jig" ".c" in
  let exe = cfile ^ ".exe" in
  let oc = open_out cfile in
  output_string oc src;
  (* oracle-side-only definitions (e.g. the int64_t m_fixed originals: OUR side gets
     the intrinsic + libc/fixed.c, the gcc side the genuine 64-bit article) *)
  output_string oc "\n";
  output_string oc gcc_extra;
  (* the driver's two needs, declared rather than #included: headers would re-typedef
     size_t as -m32's unsigned int and clash with the libc samples' unsigned-long
     prototypes (which mirror the host-preprocessed .i files CIL merges against) *)
  output_string
    oc
    "\n\
     extern int printf(const char *, ...);\n\
     extern long strtol(const char *, char **, int);\n";
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
    (* string literals (CStr): a char* to bytes interned in the data image (Globals), addressed
       DB-relative. The pointer value isn't comparable across address spaces, but the *bytes* are
       — every sample dereferences (char is unsigned, ABI §1, so 'A' = 65 on both sides). *)
  ; ( "int sidx(int i){ char *s = \"ABCD\"; return s[i & 3]; }"
    , "sidx"
    , 1 (* index a literal: 'A'..'D' = 65..68 *) )
  ; ( "int slen(int i){ char *s = \"hello\"; int n = 0; while (s[n]) n++; return n + i; }"
    , "slen"
    , 1 (* iterate to the NUL terminator → 5 + i (proves the NUL is placed) *) )
  ; ( "int rdc(char *p, int i){ return p[i]; } int spass(int i){ return rdc(\"WXYZ\", i \
       & 3); }"
    , "spass"
    , 1 (* a literal as a *call argument* (the printf shape) → 'W'..'Z' *) )
  ; ( "int smulti(int i){ char *a = \"AB\", *b = \"cd\"; return a[i & 1] + b[i & 1]; }"
    , "smulti"
    , 1 (* two distinct literals coexisting → ('A'|'B') + ('c'|'d') *) )
    (* division (ABI §5): / and % lower to Runtime helper calls — __div/__mod wrap the
       floored, positive-divisor-only hardware DIV into C's truncating semantics;
       __udiv/__umod ride DIV' (exact unsigned) plus the big-divisor 0/1 path. The §7-1a
       vectors: all four sign combinations, both operators, with masked operands so no
       sample divides by zero or computes INT_MIN/-1 (both C UB — gcc traps on them). *)
  ; ( "int dpp(int a,int b){ a &= 0x7FFFFFFF; b = (b & 0x3FFF) + 1; return a / b; }"
    , "dpp"
    , 2 (* +/+ : floored = truncated, the easy quadrant *) )
  ; ( "int dnp(int a,int b){ a = -(a & 0x7FFFFFFF); b = (b & 0x3FFF) + 1; return a / b; }"
    , "dnp"
    , 2 (* −/+ : the floor→trunc fix-up (q+1 when inexact) *) )
  ; ( "int dpn(int a,int b){ a &= 0x7FFFFFFF; b = -((b & 0x3FFF) + 1); return a / b; }"
    , "dpn"
    , 2 (* +/− : divisor negated (envelope), quotient negated after *) )
  ; ( "int dnn(int a,int b){ a = -(a & 0x7FFFFFFF); b = -((b & 0x3FFF) + 1); return a / \
       b; }"
    , "dnn"
    , 2 (* −/− : both wraps at once *) )
  ; ( "int mpp(int a,int b){ a &= 0x7FFFFFFF; b = (b & 0x3FFF) + 1; return a % b; }"
    , "mpp"
    , 2 )
  ; ( "int mnp(int a,int b){ a = -(a & 0x7FFFFFFF); b = (b & 0x3FFF) + 1; return a % b; }"
    , "mnp"
    , 2 (* −/+ : remainder H−b when inexact — sign follows the dividend *) )
  ; ( "int mpn(int a,int b){ a &= 0x7FFFFFFF; b = -((b & 0x3FFF) + 1); return a % b; }"
    , "mpn"
    , 2 (* +/− : a % b = a % |b| — divisor sign is irrelevant to C's % *) )
  ; ( "int mnn(int a,int b){ a = -(a & 0x7FFFFFFF); b = -((b & 0x3FFF) + 1); return a % \
       b; }"
    , "mnn"
    , 2 )
  ; ( "int dfull(int a,int b){ b |= 1; if (b == -1) b = 3; return a / b; }"
    , "dfull"
    , 2
      (* full-range dividend incl. INT_MIN; odd divisor, never 0 or −1 (INT_MIN/−1 UB) *)
    )
  ; "int mfull(int a,int b){ b |= 1; if (b == -1) b = 3; return a % b; }", "mfull", 2
  ; ( "int dm(int a,int b){ b |= 1; if (b == -1) b = 3; return (a / b) * b + a % b - a; }"
    , "dm"
    , 2 (* the C99 identity (a/b)*b + a%b == a → 0; catches any /-% disagreement *) )
  ; ( "int dmin(int b){ b = (b & 0x3FFF) + 2; int a = -2147483647 - 1; return a / b + a \
       % b; }"
    , "dmin"
    , 1
      (* INT_MIN dividend — the un-negatable value rides the hardware's own sign handling *)
    )
  ; ( "int dbymin(int a){ int m = -2147483647 - 1; return (a | 1) / m + (a | 1) % m; }"
    , "dbymin"
    , 1
      (* INT_MIN divisor — the helpers' special case (−INT_MIN wraps); a|1 is odd, never \
           INT_MIN, so → 0 + (a|1) *)
    )
  ; ( "int dhalf(int a){ return a / 2; }"
    , "dhalf"
    , 1 (* the classic; promoted from the retired `d` reject *) )
  ; ( "int udf(int a,int b){ unsigned x = (unsigned)a, y = (unsigned)b | 1u; return \
       (int)(x / y); }"
    , "udf"
    , 2
      (* unsigned full-range: y odd, spans both the DIV' path and the big-divisor path *)
    )
  ; ( "int umf(int a,int b){ unsigned x = (unsigned)a, y = (unsigned)b | 1u; return \
       (int)(x % y); }"
    , "umf"
    , 2 )
  ; ( "int ubig(int a,int b){ unsigned x = (unsigned)a, y = (unsigned)b | 0x80000000u; \
       return (int)(x / y) + (int)(x % y); }"
    , "ubig"
    , 2
      (* divisor top bit forced: quotient is 0 or 1, remainder a or a−b — the slow path *)
    )
  ; ( "struct s3 { int a; int b; int c; }; struct s3 sa[4]; int ppd(int i){ struct s3 *p \
       = sa + (i & 3); struct s3 *q = sa; return p - q; }"
    , "ppd"
    , 1
      (* non-pow-2 ptr−ptr (12-byte elem) through __div; promoted from the retired reject *)
    )
  ; ( "struct t3 { int a; int b; int c; }; struct t3 g3[8]; int pnd(int i){ struct t3 *p \
       = &g3[i & 7]; struct t3 *q = &g3[(i & 15) >> 1]; return p - q; }"
    , "pnd"
    , 1 (* non-pow-2 ptr−ptr with a *negative* gap — exact division is sign-safe *) )
  ; ( "int dmix(int a,int b){ b = (b & 255) + 2; return (a ^ b) + (a / b) * (a - b) + (a \
       % b); }"
    , "dmix"
    , 2 (* live temporaries across the helper BL — the save/restore protocol under load *)
    )
  ; ( "int ddn(int a,int b){ b = (b & 255) + 2; return (a / b) / ((b % 5) + 6); }"
    , "ddn"
    , 2
      (* nested divisions: the inner call's use of the div area completes before the \
           outer's begins *)
    )
    (* global initializers with link-time addresses: pointer-valued inits become relocs —
       (image offset, DB-relative target) — patched to absolute DB + target by the image
       consumer (here dcc_compile, playing loader at Runner.data_base; later the 3b linker).
       Typed NULL — a cast of a cast — and compile-time double expressions under an int cast
       (DOOM's (fixed_t)(.867 * 65536) automap tables) fold to plain words. *)
  ; ( "char *msg = \"hey\"; int spi(int i){ return msg[i & 2]; }"
    , "spi"
    , 1 (* string-pointer init: the s6 intern + a reloc; read through the pointer *) )
  ; ( "char *msg2 = \"hi\"; int sl(int x){ if (msg2) return x; return 1; }"
    , "sl"
    , 1 (* promoted from the retired reject: the reloc'd pointer is non-null *) )
  ; ( "int gx = 7; int *gp = &gx; int rp(int i){ return *gp + i; }"
    , "rp"
    , 1 (* &global init: read through *) )
  ; ( "int gx2 = 1; int *gp2 = &gx2; int wp(int i){ *gp2 = i * 3; return gx2; }"
    , "wp"
    , 1 (* write through the reloc'd pointer, read the target — real aliasing *) )
  ; ( "int garr[4] = {10,20,30,40}; int *gpa = garr; int ra(int i){ return gpa[i & 3]; }"
    , "ra"
    , 1 (* array-decay init (StartOf) *) )
  ; ( "int garr2[4] = {10,20,30,40}; int *gpm = &garr2[2]; int rm(int i){ return gpm[i & \
       1]; }"
    , "rm"
    , 1 (* &arr[2]: a constant-index addend folded into the reloc target *) )
  ; ( "int ga = 5; int gb = 9; int *tbl[4] = { &ga, 0, &gb, 0 }; int rt(int i){ int *q = \
       tbl[i & 3]; if (q) return *q; return -1; }"
    , "rt"
    , 1 (* relocs and typed NULLs coexisting in one CompoundInit *) )
  ; ( "struct ent { int v; int *link; }; int tgt = 3; struct ent e0 = { 5, &tgt }; int \
       sptr(int i){ return *e0.link + e0.v + i; }"
    , "sptr"
    , 1 (* a reloc inside a struct initializer *) )
  ; ( "char *np = (void *)0; int nul(int i){ if (np) return 0; return i; }"
    , "nul"
    , 1 (* typed NULL — the cast-of-a-cast the one-level peek missed *) )
  ; ( "typedef int fixed_t; fixed_t sc = (fixed_t)(.867 * (double)65536); int fxc(int \
       i){ return sc + i; }"
    , "fxc"
    , 1 (* the automap-table shape: compile-time double math, C-truncating cast → 56819 *)
    )
  ; ( "typedef int fixed_t; fixed_t nsc = (fixed_t)(-.7 * (double)65536); int fxn(int \
       i){ return nsc + i; }"
    , "fxn"
    , 1 (* negative: -45875.2 truncates toward zero → -45875, not floor's -45876 *) )
    (* call result to a memory lval: the result sits in R0 — the lowest scratch, exactly
       what the destination's address calculus would grab first — so the store claims R0
       busy while gen_addr runs. Destinations: global, deref, field, array, sub-word. *)
  ; ( "int cgv; int idg(int x){ return x * 3; } int cres(int i){ cgv = idg(i); return \
       cgv + 1; }"
    , "cres"
    , 1 (* plain global destination: g = f(i) stays a direct Call(Some g) — no CIL temp *)
    )
  ; ( "int idp(int x){ return x - 5; } int cptr2(int i){ int x = 0; int *p = &x; *p = \
       idp(i); return x; }"
    , "cptr2"
    , 1 (* deref destination: *p = f(i) — the pointer loads into a scratch above R0 *) )
  ; ( "struct cpt { int x; int y; }; struct cpt gcp = {3, 0}; int idq(int x){ return x ^ \
       7; } int cfld(int i){ gcp.y = idq(i); return gcp.y + gcp.x; }"
    , "cfld"
    , 1 (* field destination: constant residual, general path *) )
  ; ( "int cga[4]; int ida(int x){ return x + 9; } int cidx(int i){ cga[(i & 0x7FFF) % \
       4] = ida(i); return cga[(i & 0x7FFF) % 4]; }"
    , "cidx"
    , 1
      (* THE composition test: a __mod call inside the destination index while R0 holds \
           the result — the div-area protocol saves/restores the claimed R0 *)
    )
  ; ( "char cgc; int idc2(int x){ return x; } int cch(int i){ cgc = idc2(i); return cgc; }"
    , "cch"
    , 1 (* sub-word destination: STB truncates, LDB re-widens — mod-256 both sides *) )
    (* unions: members all at byte offset 0, size/align = max over members; a static
       initializer names exactly one member and the rest stays zero. DOOM's unions are
       actionf_t (function-pointer variants) and intercept_t's thing/line — same-width
       scalars; type-punning through memory is well-defined here because both sides are
       little-endian and every access is a real load/store. *)
  ; ( "union uv { int i; char c[4]; }; union uv gu; int ur(int i){ gu.i = i; return \
       gu.c[0] + gu.c[1] * 256; }"
    , "ur"
    , 1 (* bss union global + punning: write .i, read bytes back (LE) *) )
  ; ( "union uw { int i; short s; }; union uw guw = { 42 }; int uwr(int i){ return guw.i \
       + i; }"
    , "uwr"
    , 1 (* initialized union: the first member takes the value *) )
  ; ( "struct th { int x; union { int a; unsigned b; } u; }; struct th gth = { 1, { 2 } \
       }; int thr(int i){ return gth.x + gth.u.a + i; }"
    , "thr"
    , 1 (* union nested in a struct — the thinker_t/actionf_t shape *) )
  ; ( "union pu { int *p; char *q; }; int pux = 258; union pu gpu = { &pux }; int \
       upr(int i){ return *gpu.p + gpu.q[0] + i; }"
    , "upr"
    , 1
      (* an s8 reloc inside a union init; deref via .p and pun via .q (LE low byte = 2) *)
    )
  ; ( "union uv2 { int i; char c[4]; }; int ulc(int i){ union uv2 v; v.i = i * 5 + 1; \
       return v.c[3]; }"
    , "ulc"
    , 1 (* union LOCAL: slotted (aggregate), punned through the frame slot *) )
    (* the spilling rungs (2-3): >6 params spill via a prologue copy from FP+4i; a big
       leaf DEMOTES to the split shape (homes R6-R11, spills, >= 6 scratch) — the
       runner's R6-R11 sentinels verify its new save obligation; and scratch WIDENS to
       unused home registers, so deep expressions get up to 12-homes temporaries. *)
  ; ( "int p7(int a,int b,int c,int d,int e,int f,int g){ return a + b*2 + c*3 + d*4 + \
       e*5 + f*6 + g*7; }"
    , "p7"
    , 7
      (* 7 params, leaf -> demoted split: a..f homed, g SPILLED (arrives FP+24, \
           prologue-copied to its slot); position-weighted so a wrong slot shows *)
    )
  ; ( "int add1(int x){ return x + 1; } int p8(int a,int b,int c,int d,int e,int f,int \
       g,int h){ return add1(a) + b*2 + c*3 + d*4 + e*5 + f*6 + g*7 + h*8; }"
    , "p8"
    , 8 (* 8 params, non-leaf: g and h both spilled, live across the call *) )
  ; ( "int ldeep(int a){ int t0=a+1; int t1=a+2; int t2=a+3; int t3=a+4; int t4=a+5; int \
       t5=a+6; int t6=a+7; int t7=a+8; int t8=a+9; int t9=a+10; int t10=a+11; int \
       t11=a+12; int t12=a+13; return t0*1 + t1*2 + t2*3 + t3*4 + t4*5 + t5*6 + t6*7 + \
       t7*8 + t8*9 + t9*10 + t10*11 + t11*12 + t12*13 + a; }"
    , "ldeep"
    , 1
      (* 14 register candidates in a LEAF -> demoted: 6 homes + 8 spills, saves \
           R6-R11 (sentinel-checked), no LNK save (still a leaf) *)
    )
  ; ( "int h1(int x){ return x; } int sdeep(int a, int b){ int r = h1(a); return r + \
       ((a+1) + ((b+2) + ((a+3) + ((b+4) + ((a+5) + ((b+6) + (b*a))))))); }"
    , "sdeep"
    , 2
      (* right-nested: 7+ simultaneous live temporaries — over the old fixed 6-reg \
           pool, inside the widened one (3 homes -> 9 scratch) *)
    )
    (* constant-float folds: a compile-time double expression under an int cast — the
       automap zoom idiom — computes at compile time; no float reaches runtime, and gcc
       folds the same expressions with real doubles, so the diff checks the arithmetic. *)
  ; ( "int ff1(int x){ return (int)(0.7 * 65536) + x; }"
    , "ff1"
    , 1 (* the AM_LevelInit shape: 45875 + x *) )
  ; ( "int ff2(int x){ return (int)(65536 / 1.02) + (int)(1.02 * 65536) + x; }"
    , "ff2"
    , 1 (* the AM_Responder shapes — constant float DIVISION and multiplication *) )
  ; ( "int ff3(int x){ return (char)(1.5 * 200) + x; }"
    , "ff3"
    , 1 (* width-exact narrowing through the fold: (char)300 = 44 (char unsigned) *) )
  ; ( "int ff4(int x){ return (int)(-0.7 * 65536) + x; }"
    , "ff4"
    , 1 (* negative: truncates toward zero, -45875 (not floor's -45876) *) )
    (* varargs (ABI §3 "for free"): the s4.1b marshaller leaves EVERY argument in the
       caller's home area, so va_start = FP + 4*n_formals and va_arg walks memory. The
       oracle side compiles the same headerless __builtin_* source with gcc's own
       varargs — two independent implementations of the same C semantics. *)
  ; ( "int vsum0(int n, ...){ __builtin_va_list ap; int s = 0; __builtin_va_start(ap, \
       n); while (n > 0) { s += __builtin_va_arg(ap, int); n--; } __builtin_va_end(ap); \
       return s; } int vsum(int i){ return vsum0(3, i, i * 2, 7) + vsum0(0) * 10 + \
       vsum0(1, i ^ 5); }"
    , "vsum"
    , 1 (* the shape itself: 0, 1, 3 variadic args *) )
  ; ( "int vs6(int n, ...){ __builtin_va_list ap; int s = 0; __builtin_va_start(ap, n); \
       while (n > 0) { s = s * 3 + __builtin_va_arg(ap, int); n--; } \
       __builtin_va_end(ap); return s; } int vmix(int i){ return vs6(6, i, 2, 3, 4, 5, i \
       & 7); }"
    , "vmix"
    , 1
      (* 7 total args: the variadic walk crosses the register/stack slot boundary; a \
           position-weighted fold catches any misordered slot *)
    )
  ; ( "int vf2(int a, int b, ...){ __builtin_va_list ap; int v; __builtin_va_start(ap, \
       b); v = __builtin_va_arg(ap, int); __builtin_va_end(ap); return a * 100 + b * 10 \
       + v; } int vshift(int i){ return vf2(1, 2, i & 7); }"
    , "vshift"
    , 1 (* two fixed params: the va_start anchor is FP+8, not FP+4 *) )
    (* code addresses (3b.1): a function's address exists only at link time, so &f is an
       Addr frag (expanded to the load_const pair at layout) and a fn-ptr initializer is
       a Code reloc (patched via sym_addr). An indirect call is BL-to-register: the
       pointer value evaluated between the arg stores and the R0-R3 loads, with R0-R3
       claimed so the target register sits above them. *)
  ; ( "int inc1(int x){ return x + 1; } int (*gf)(int) = inc1; int icall(int i){ return \
       gf(i) * 2; }"
    , "icall"
    , 1 (* fn-ptr GLOBAL initializer (Code reloc) + call through it; retires usefp *) )
  ; ( "int dbl2(int x){ return x * 2; } int lcall(int i){ int (*f)(int) = dbl2; return \
       f(i) + 1; }"
    , "lcall"
    , 1 (* &f into a local (Addr frag), then the indirect call *) )
  ; ( "int app(int (*fp)(int), int x){ return fp(x); } int neg1(int x){ return -x; } int \
       cbk(int i){ return app(neg1, i); }"
    , "cbk"
    , 1
      (* the callback pattern: fn passed as an arg, called indirectly in the callee — \
           the DOOM action-function shape; retires callptr *)
    )
  ; ( "int aone(int x){ return x + 1; } int atwo(int x){ return x + 2; } int \
       (*ftbl[2])(int) = { aone, atwo }; int tcall(int i){ return ftbl[i & 1](i); }"
    , "tcall"
    , 1
      (* table dispatch — the states[] actionf_t shape: Code relocs in an array, \
           indexed indirect call *)
    )
  ; ( "int s5f(int a,int b,int c,int d,int e){ return a + b*2 + c*3 + d*4 + e*5; } int \
       (*g5)(int,int,int,int,int) = s5f; int ical5(int i){ return g5(i, i+1, i+2, i+3, \
       i+4); }"
    , "ical5"
    , 1 (* indirect call with a 5th (stack) arg: marshalling + claimed R0-R3 + BL reg *) )
    (* ---- bitfields, the byte-aligned :8 degenerate case (the DG_ port slice's
       compiler half): under GCC's LSB-first little-endian allocation, struct
       color's b/g/r/a are bytes 0-3 of the word — one LDB/STB each, no
       read-modify-write. bf1 pins the LAYOUT itself: it writes fields and reads
       the raw bytes back through a char*, so if CIL's machdep ever disagreed
       with gcc's allocation rule the diff explodes on the spot. ---- *)
  ; ( "struct color { unsigned int b:8; unsigned int g:8; unsigned int r:8; unsigned int \
       a:8; }; int bf1(int x){ struct color c; unsigned char *p = (unsigned char *)&c; \
       c.b = 1; c.g = 2; c.r = x; c.a = 4; return p[0] + p[1] * 10 + p[2] * 100 + p[3] * \
       1000; }"
    , "bf1"
    , 1 (* the layout pin: field writes observed as raw bytes; c.r = x truncates *) )
  ; ( "struct color { unsigned int b:8; unsigned int g:8; unsigned int r:8; unsigned int \
       a:8; }; int bf2(int x){ struct color c; c.b = 10; c.g = 20; c.r = 30; c.a = 40; \
       c.g = c.g + x; return c.b + c.g * 100 + c.r * 10000 + c.a * 1000000; }"
    , "bf2"
    , 1
      (* read-modify one field: the other three provably untouched (an STW-shaped
           store would clobber them; the neighbors are the witnesses) *)
    )
  ; ( "struct color { unsigned int b:8; unsigned int g:8; unsigned int r:8; unsigned int \
       a:8; }; struct color colors[4]; unsigned char tab[6] = {3,1,4,1,5,9}; int bf3(int \
       i){ int k; for (k = 0; k < 4; k++) { colors[k].a = 0; colors[k].r = tab[k]; \
       colors[k].g = tab[k + 1]; colors[k].b = tab[k + 2]; } return colors[i & 3].r + \
       colors[(i + 1) & 3].g * 100 + colors[2].b * 10000; }"
    , "bf3"
    , 1
      (* the I_SetPalette shape verbatim: global struct-color array (placement
           relaxation) filled from a byte table, indexed field access both ways *)
    )
  ; ( "struct color { unsigned int b:8; unsigned int g:8; unsigned int r:8; unsigned int \
       a:8; }; int bf4(int x){ struct color c; c.g = 300; c.b = (x & 4095) * 5; return \
       c.g * 100000 + c.b * 100 + 7; }"
    , "bf4"
    , 1 (* store-truncation: 300 -> 44, and a wide expression narrowed by STB *) )
  ; ( "struct sbf { int v:8; int w:8; }; int bf5(int x){ struct sbf s; s.v = x; s.w = \
       200; return s.v * 1000 + s.w; }"
    , "bf5"
    , 1
      (* signed :8: reads sign-extend (LDB + narrow, s3.3b); out-of-range stores
           wrap modulo like gcc's (200 -> -56) *)
    )
  ; ( "struct color { unsigned int b:8; unsigned int g:8; unsigned int r:8; unsigned int \
       a:8; }; struct color gc = { 5, 6, 7, 8 }; int bf6(int i){ unsigned char *p = \
       (unsigned char *)&gc; return p[0] + p[1] * 10 + p[2] * 100 + p[3] * 1000 + gc.r + \
       (i - i); }"
    , "bf6"
    , 1
      (* a CompoundInit over bitfields: the serializer must write ONE byte per
           field (the declared uint32 width would clobber the neighbors) *)
    )
  ]
;;

(* The pre-codegen gate must REFUSE these (ABI §4 bans + not-yet-supported forms),
   raising Unsupported rather than silently miscompiling. Note `int k(int *p){ return *p; }`
   COMPILES as of s3.2a but can't run here — the harness passes ints, and a random int is
   not a valid pointer on either side; deref coverage comes from drf/arrow above. *)
let rejects =
  [ "float f(float x){ return x; }", "f" (* float — ABI §4 *)
  ; "long long g(long long x){ return x + 1; }", "g" (* 64-bit — ABI §4 *)
  ; ( "struct pt { int x; int y; }; extern struct pt mk(int); int usemk(int x){ struct \
       pt p = mk(x); return p.x; }"
    , "usemk" (* aggregate return by value — none in DOOM (census); deferred *) )
  ; ( "extern int ext; int rex(int x){ return ext + x; }"
    , "rex" (* declared, never defined — 3b linker *) )
  ; ( "struct t3 { unsigned int v:3; }; int rj3(int x){ struct t3 s; s.v = x; return \
       s.v; }"
    , "rj3" (* a real bitfield (:3) — only the byte-aligned :8 degenerate lowers *) )
  ; ( "struct t48 { unsigned int a:4; unsigned int b:8; }; int rj48(int x){ struct t48 \
       s; s.b = x; return s.b; }"
    , "rj48" (* an :8 pushed off-byte (bit offset 4) — width alone isn't enough *) )
  ; ( "struct t5 { unsigned int v:5; }; int rjp(int x){ return ((struct t5 *)&x)->v; }"
    , "rjp"
      (* a banned bitfield reached through a CAST pointer: no declaration gate ever
         sees struct t5, so this exercises gen_addr/classify_access's own guard *)
    )
  ]
;;

(* ---- mini-libc samples (1c): compiled WITH libc/mini.c merged in on our side, and
   against the host's real glibc on the oracle side — our memcpy vs the genuine
   article. Authorship notes: strcmp-family results are sign-normalized ((r>0)-(r<0):
   C leaves the magnitude unspecified); str* pointer results convert to indexes or
   null-flags before crossing the diff; the heap globals bind the bump arena inside
   emulator RAM (glibc ignores them and uses its own heap). *)
let libc_prelude =
  "char *__heap_base = (char *)0x90000; char *__heap_end = (char *)0xF0000; extern void \
   *memcpy(void *, const void *, unsigned long); extern void *memmove(void *, const void \
   *, unsigned long); extern void *memset(void *, int, unsigned long); extern unsigned \
   long strlen(const char *); extern int strcmp(const char *, const char *); extern int \
   strncmp(const char *, const char *, unsigned long); extern int strcasecmp(const char \
   *, const char *); extern int strncasecmp(const char *, const char *, unsigned long); \
   extern char *strchr(const char *, int); extern char *strrchr(const char *, int); \
   extern char *strstr(const char *, const char *); extern char *strncpy(char *, const \
   char *, unsigned long); extern char *strdup(const char *); extern int toupper(int); \
   extern int abs(int); extern int atoi(const char *); extern void *malloc(unsigned \
   long); extern void *calloc(unsigned long, unsigned long); extern void *realloc(void \
   *, unsigned long); extern void free(void *); extern int snprintf(char *, unsigned \
   long, const char *, ...); extern int vsnprintf(char *, unsigned long, const char *, \
   __builtin_va_list); "
;;

let libc_samples =
  List.map
    (fun (src, name, arity) -> libc_prelude ^ src, name, arity)
    [ ( "int mcp(int i){ char b[8]; memcpy(b, \"ABCDEFG\", 8); return b[i & 7]; }"
      , "mcp"
      , 1 (* memcpy from a string literal into a frame buffer *) )
    ; ( "int mmv(int i){ char b[10]; int k; for (k = 0; k < 10; k++) b[k] = k + (i & 7); \
         if (i & 1) memmove(b + 2, b, 6); else memmove(b, b + 2, 6); return b[i & 7]; }"
      , "mmv"
      , 1 (* overlapping moves, both directions — the memmove reason-for-being *) )
    ; ( "int mst(int i){ char b[8]; memset(b, i, 6); b[6] = 7; return b[i & 7]; }"
      , "mst"
      , 1 (* memset truncates the fill byte; b[6..7] untouched past n *) )
    ; ( "int xlen(int i){ char b[10]; int n = i & 7; int k; for (k = 0; k < n; k++) b[k] \
         = 'a'; b[n] = 0; return (int)strlen(b) * 10 + (int)strlen(\"hello\"); }"
      , "xlen"
      , 1 )
    ; ( "int xcmp(int i){ char b[4]; b[0] = 'a'; b[1] = 'a' + (i & 3); b[2] = 0; int r = \
         strcmp(b, \"ab\"); int s = strncmp(b, \"ab\", 1); return ((r > 0) - (r < 0)) * \
         10 + ((s > 0) - (s < 0)); }"
      , "xcmp"
      , 1 (* sign-normalized: C leaves the magnitude unspecified *) )
    ; ( "int xcas(int i){ int r = strcasecmp(\"MiXeD\", \"mixed\"); int s = \
         strncasecmp(\"ABc\", (i & 1) ? \"abd\" : \"abc\", 3); return ((r > 0) - (r < \
         0)) * 10 + ((s > 0) - (s < 0)); }"
      , "xcas"
      , 1 )
    ; ( "int xchr(int i){ const char *s = \"hello\"; char *p = strchr(s, \"lox\"[(i & 3) \
         % 3]); char *q = strrchr(s, 'l'); return (p ? (int)(p - s) : -1) * 10 + (q ? \
         (int)(q - s) : -1); }"
      , "xchr"
      , 1 (* found / not-found / rightmost — results as indexes, never raw pointers *) )
    ; ( "int xstr(int i){ const char *h = \"the cat sat\"; char *p = strstr(h, (i & 1) ? \
         \"cat\" : \"dog\"); char *q = strstr(h, \"\"); return (p ? (int)(p - h) : -1) * \
         10 + (q ? (int)(q - h) : -1); }"
      , "xstr"
      , 1 (* hit, miss, and the empty-needle rule *) )
    ; ( "int xncp(int i){ char b[6]; memset(b, 0x55, 6); strncpy(b, \"ab\", 5); return \
         b[(i & 7) % 6]; }"
      , "xncp"
      , 1 (* the NUL-padding rule: b[2..4] zeroed, b[5] still 0x55 *) )
    ; ( "int xdup(int i){ char src[4]; src[0] = 'x'; src[1] = 'y' + (i & 1); src[2] = 0; \
         char *p = strdup(src); src[0] = '!'; return p[0] * 100 + p[1]; }"
      , "xdup"
      , 1 (* the copy is independent: mutating src can't reach it *) )
    ; ( "int xcnv(int i){ char b[8]; b[0] = ' '; b[1] = (i & 1) ? '-' : '+'; b[2] = '4'; \
         b[3] = '2'; b[4] = (i & 2) ? 'x' : '7'; b[5] = 0; return atoi(b) * 10 + \
         toupper(\"aZ4\"[(i & 3) % 3]) + abs(i & 15); }"
      , "xcnv"
      , 1 (* atoi: spaces, signs, trailing junk; toupper across cases; abs *) )
    ; ( "int lmal(int i){ int *a = malloc(12); int *b = malloc(8); a[0] = i; a[2] = i + \
         2; b[0] = i * 3; return a[0] + a[2] + b[0] + (((int)a & 7) == 0) + (((int)b & \
         7) == 0); }"
      , "lmal"
      , 1 (* two live blocks, no overlap; 8-alignment as a boolean (glibc -m32 agrees) *)
      )
    ; ( "int lcal(int i){ int *p = calloc(4, 4); int k; int s = 0; for (k = 0; k < 4; \
         k++) s += p[k]; p[1] = i; return s * 100 + p[1]; }"
      , "lcal"
      , 1 (* calloc zeroes — against a poisoned bump arena that would show through *) )
    ; ( "int lrea(int i){ int *p = malloc(8); p[0] = i; p[1] = i ^ 5; int *q = \
         realloc(p, 16); q[2] = 9; return q[0] + q[1] + q[2]; }"
      , "lrea"
      , 1 (* grow preserves the old prefix *) )
      (* the printf core, diffed against glibc's: buffers pre-filled so bytes past the
         NUL are deterministic on both sides, results folded as a checksum *)
    ; ( "int vsn1(int i){ char b[40]; int k; int s; int r; memset(b, 7, 40); r = \
         snprintf(b, 40, \"a=%d b=%u c=%x\", i, (unsigned)i, i & 255); s = r; for (k = \
         0; k < 40; k++) s = s * 31 + b[k]; return s; }"
      , "vsn1"
      , 1 (* the basics: %d full-range (incl. INT_MIN), %u, %x *) )
    ; ( "int vsn2(int i){ char b[8]; int k; int s; int r; memset(b, 9, 8); r = \
         snprintf(b, 8, \"v=%d!\", i); s = r * 1000; for (k = 0; k < 8; k++) s = s * 31 \
         + b[k]; return s; }"
      , "vsn2"
      , 1 (* truncation: returns the WOULD-BE length, buffer cut + NUL-terminated *) )
    ; ( "int vsn3(int i){ char b[48]; int k; int s; int r; memset(b, 3, 48); r = \
         snprintf(b, 48, \"[%05d][%-6d][%4x][%.3s]\", i, i & 63, i & 4095, \"abcdef\"); \
         s = r; for (k = 0; k < 48; k++) s = s * 31 + b[k]; return s; }"
      , "vsn3"
      , 1 (* zero-pad (sign-aware), left-align, width, %s precision *) )
    ; ( "int vsn4(int i){ char b[32]; int k; int s; int r; memset(b, 5, 32); r = \
         snprintf(b, 32, \"[%c]%%[%s][%X]\", 'A' + (i & 7), (i & 1) ? \"yes\" : \"no\", \
         (unsigned)i >> 16); s = r; for (k = 0; k < 32; k++) s = s * 31 + b[k]; return \
         s; }"
      , "vsn4"
      , 1 (* %c, %%, %s branches, %X uppercase *) )
    ]
;;

(* ---- m_fixed (1a meets the intrinsic): FixedMul expands inline at link (MUL + read
   H + repack — the §1 "near custom-built" moment) and FixedDiv is libc/fixed.c's
   16-step restoring division. The oracle side compiles doomgeneric's REAL int64_t
   originals (gcc_extra — our side never sees them), so the diff pits our 32-bit
   machinery against genuine 64-bit arithmetic over full-range fixed-point pairs. *)
let fixed_ref =
  "static int _fm_abs(int x){ return x < 0 ? -x : x; } int FixedMul(int a, int b){ \
   return (int)(((long long)a * (long long)b) >> 16); } int FixedDiv(int a, int b){ if \
   ((_fm_abs(a) >> 14) >= _fm_abs(b)) return (a ^ b) < 0 ? (int)0x80000000 : \
   (int)0x7FFFFFFF; { long long r = ((long long)a << 16) / b; return (int)r; } }\n"
;;

let fixed_samples =
  (* the heap globals bind mini.c's malloc (merged with everything) inside emulator RAM *)
  List.map (fun (src, name, arity) ->
    ( "char *__heap_base = (char *)0x90000; char *__heap_end = (char *)0xF0000; " ^ src
    , name
    , arity ))
  @@ [ ( "extern int FixedMul(int, int); int fxm(int a, int b){ return FixedMul(a, b); }"
       , "fxm"
       , 2 (* full-range: any dropped high word (the miscompile this slice fixes) shows *)
       )
     ; ( "extern int FixedMul(int, int); int fxmi(int a){ return FixedMul(a, 1 << 16) - \
          a; }"
       , "fxmi"
       , 1 (* the unit identity: a * 1.0 == a, exact for every a *) )
     ; ( "extern int FixedDiv(int, int); int fxd(int a, int b){ a |= 1; return \
          FixedDiv(a, b); }"
       , "fxd"
       , 2
         (* full-range with a != INT_MIN (the original's abs-overflow quirk diverges \
           there); b = 0 rides the saturation guard on both sides *)
       )
     ; ( "extern int FixedDiv(int, int); int fxdi(int a){ a = (a & 0xFFFFFF) - 0x800000; \
          return FixedDiv(a, 1 << 16) - a; }"
       , "fxdi"
       , 1 (* the unit identity: a / 1.0 == a across ±2^23 (inside the guard) *) )
     ; ( "extern int FixedMul(int, int); extern int FixedDiv(int, int); int fxc2(int a, \
          int b){ b |= 1; int m = FixedMul(a, b); int d = FixedDiv(a, b); return m + d * \
          3; }"
       , "fxc2"
       , 2 (* both in one frame: the intrinsic expansion and the C division coexisting *)
       )
     ]
;;

(* ---- self-checks (1c.3): the memory-file registry has no glibc counterpart, so
   these compile with the full libc and verify against hand-computed constants instead
   of an oracle. They must not touch the console functions — the bare jig emulator has
   no serial attached, and the UART tx-ready wait would spin forever. ---- *)
let libc_selfchecks =
  [ ( "char *__heap_base = (char *)0x90000; char *__heap_end = (char *)0xF0000; typedef \
       struct _IO_FILE FILE; extern void __file_register(const char *, const void *, \
       unsigned long); extern FILE *fopen(const char *, const char *); extern int \
       fclose(FILE *); extern unsigned long fread(void *, unsigned long, unsigned long, \
       FILE *); extern int fseek(FILE *, long, int); extern long ftell(FILE *); char \
       fdata[8] = {10,20,30,40,50,60,70,80}; int sc1(int i){ FILE *f; char b[4]; char c; \
       char e; int n; int t1; int m; int w; __file_register(\"wad\", fdata, 8); f = \
       fopen(\"wad\", \"rb\"); if (!f) return -1; n = (int)fread(b, 1, 3, f); t1 = \
       (int)ftell(f); fseek(f, 2, 0); fread(&c, 1, 1, f); fseek(f, -1, 2); fread(&e, 1, \
       1, f); m = fopen(\"nope\", \"rb\") == 0; w = fopen(\"wad\", \"w\") == 0; \
       fclose(f); return n + t1 * 10 + c + e * 100 + m * 1000 + w * 2000 + b[1] + (i - \
       i); }"
    , "sc1"
      (* register + open + read + SEEK_SET/END + miss + write-refusal + fclose:
         3 + 3*10 + 30 + 80*100 + 1000 + 2000 + 20 *)
    , [ 0, 11083; 5, 11083; -3, 11083 ] )
  ; ( "char *__heap_base = (char *)0x90000; char *__heap_end = (char *)0xF0000; typedef \
       struct _IO_FILE FILE; extern void __file_register(const char *, const void *, \
       unsigned long); extern FILE *fopen(const char *, const char *); extern int \
       fclose(FILE *); extern unsigned long fread(void *, unsigned long, unsigned long, \
       FILE *); extern int fseek(FILE *, long, int); extern long ftell(FILE *); char \
       g1[6] = {1,2,3,4,5,6}; char g2[3] = {9,8,7}; int sc2(int i){ FILE *a; FILE *b; \
       char x; char y; int r1; int r2; int over; int tl; __file_register(\"a\", g1, 6); \
       __file_register(\"b\", g2, 3); a = fopen(\"a\", \"rb\"); b = fopen(\"b\", \
       \"rb\"); fseek(a, 4, 0); fseek(a, 1, 1); fread(&x, 1, 1, a); r1 = (int)fread(&x, \
       1, 1, a); fread(&y, 1, 1, b); over = fseek(b, 9, 0); tl = (int)ftell(b); r2 = \
       (int)fread(&y, 1, 1, b); fclose(a); fclose(b); return x + r1 * 10 + y * 100 + \
       over * 1000 + tl * 10000 + r2 + (i - i); }"
    , "sc2"
      (* two live handles, SEEK_CUR, read-at-EOF (0 items, dest untouched),
         out-of-range seek fails without moving: 6 + 0 + 8*100 - 1000 + 10000 + 1 *)
    , [ 0, 9807; 9, 9807 ] )
  ]
;;

(* ---- the ~port sample prelude: binds every extern the platform layer reads.
   Himem addresses point into safe emulator RAM — __shared_base at 0x78000 (a free
   4 KB between the stack top 0x70000 and the data segment 0x80000), __fb_base at
   0xC0000 (96 KB of framebuffer ending at 0xD8000, clear of the data image and the
   unused heap). The DOOM-side globals (colors / palette_changed / DG_ScreenBuffer
   — defined by i_video/doomgeneric in the real tree) must be defined here too:
   DG_DrawFrame merges in with every ~port sample, and an extern without a
   definition refuses the whole compile. Console functions stay off-limits as ever
   (no serial attached). ---- *)
let port_prelude =
  "char *__heap_base = (char *)0x90000; char *__heap_end = (char *)0xF0000; char \
   *__shared_base = (char *)0x78000; char *__fb_base = (char *)0xC0000; struct color { \
   unsigned int b:8; unsigned int g:8; unsigned int r:8; unsigned int a:8; }; struct \
   color colors[256]; unsigned int palette_changed; unsigned char *DG_ScreenBuffer; \
   extern void DG_KeyEnqueue(int pressed, unsigned char key); extern int DG_GetKey(int \
   *pressed, unsigned char *key); extern unsigned int DG_GetTicksMs(); extern void \
   DG_SleepMs(unsigned int ms); extern void DG_DrawFrame(void); extern void \
   __dg_build_lut(const unsigned char *pal); extern void __dg_dither(const unsigned char \
   *src, int w, int h, unsigned int *dst, int stride); extern int Init(int wad_addr, int \
   cfg_addr); extern int Tick(void); extern void KeyIn(int ev); extern void exit(int \
   status); extern int __setjmp(unsigned int *env); extern void __longjmp(unsigned int \
   *env, int val); extern unsigned int __exit_env[9]; "
;;

(* ---- self-checks (port slice): the DG_ hooks' machine surface — the SHARED-page
   key ring (pure memory, fully checkable), the ms-counter spin (checkable since
   the Runner ticks the synthetic clock; the real assertion in [slp] is TERMINATION —
   a frozen clock would spin DG_SleepMs into the step cap), and the dither kernel's
   SEMANTICS ([kd1]: hand-computed packed words pin LSB-leftmost bit order, the
   Bayer thresholds, 2x2 doubling, and the stride-as-flip contract — the
   differential samples below can't catch a wrong-but-deterministic algorithm,
   since both sides run the same C). ---- *)
let port_selfchecks =
  List.map (fun (src, name, cases) -> port_prelude ^ src, name, cases)
  @@ [ ( "int kr1(int i){ int p; unsigned char k; int acc; int n; acc = 0; n = 0; if \
          (DG_GetKey(&p, &k)) return -1; DG_KeyEnqueue(1, 173); DG_KeyEnqueue(0, 173); \
          DG_KeyEnqueue(1, 32); while (DG_GetKey(&p, &k)) { acc = acc * 1000 + k + p * \
          500; n++; } return acc + n + (i - i); }"
       , "kr1"
         (* empty-at-start + FIFO order + both event bytes:
            (173+500)*1000000 + 173*1000 + (32+500) + 3 *)
       , [ 0, 673173535; 9, 673173535 ] )
     ; ( "int kr2(int i){ unsigned int *head; unsigned int *tail; int p; unsigned char \
          k; int r; head = (unsigned int *)(__shared_base + 20); tail = (unsigned int \
          *)(__shared_base + 24); *head = 0xFFFFFFFEu; *tail = 0xFFFFFFFEu; \
          DG_KeyEnqueue(1, 11); DG_KeyEnqueue(1, 22); DG_KeyEnqueue(0, 33); \
          DG_GetKey(&p, &k); r = k; DG_GetKey(&p, &k); r = r * 100 + k; DG_GetKey(&p, \
          &k); r = r * 100 + k + p; if (DG_GetKey(&p, &k)) r = -r; return r + (i - i); }"
       , "kr2"
         (* the free-running-counter contract: head/tail seeded at 0xFFFFFFFE, three
            events ride slots 254, 255, 0 across the u32 rollover, drain in order,
            ring empty after: 11*10000 + 22*100 + 33 *)
       , [ 0, 112233; -5, 112233 ] )
     ; ( "int kr3(int i){ int j; int c; int p; unsigned char k; int last; c = 0; last = \
          0; for (j = 0; j < 300; j++) DG_KeyEnqueue(1, (unsigned char)j); while \
          (DG_GetKey(&p, &k)) { c++; last = k; } return c * 1000 + last + (i - i); }"
       , "kr3"
         (* full-ring drop: 300 offered, exactly 256 accepted (keys 0..255) and the
            rest dropped — an over-accepting ring would overwrite live slots and
            surface as c > 256 or a wrapped last key (last != 255) *)
       , [ 0, 256255; 3, 256255 ] )
     ; ( "int slp(int i){ unsigned int t0; unsigned int t1; t0 = DG_GetTicksMs(); \
          DG_SleepMs(3); t1 = DG_GetTicksMs(); return (t1 - t0 >= 3u) + (i - i); }"
       , "slp"
         (* the spin waits at least [ms] on the Runner's synthetic clock — and
            terminates, which is the assertion a frozen clock would fail *)
       , [ 0, 1; 2, 1 ] )
     ; ( "unsigned char pal[1024]; unsigned char fr[32]; unsigned int ob[4]; unsigned \
          int oc[4]; int kd1(int i){ int k; int r; for (k = 0; k < 1024; k++) pal[k] = \
          0; pal[4] = 255; pal[5] = 255; pal[6] = 255; pal[8] = 128; pal[9] = 128; \
          pal[10] = 128; __dg_build_lut(pal); for (k = 0; k < 8; k++) fr[k] = 0; for (k \
          = 8; k < 16; k++) fr[k] = 1; for (k = 16; k < 32; k++) fr[k] = 2; \
          __dg_dither(fr, 16, 2, ob, 1); r = (ob[0] == 0xFFFF0000u) + (ob[1] == \
          0xFFFF0000u) * 2 + (ob[2] == 0xCCCCCCCCu) * 4 + (ob[3] == 0xCCCCCCCCu) * 8; \
          __dg_dither(fr, 16, 2, oc + 3, -1); r += (oc[3] == 0xFFFF0000u) * 16 + (oc[2] \
          == 0xFFFF0000u) * 32 + (oc[1] == 0xCCCCCCCCu) * 64 + (oc[0] == 0xCCCCCCCCu) * \
          128; return r + (i - i); }"
       , "kd1"
         (* the dither semantics, hand-computed. Palette: 0=black, 1=white, 2=mid
            gray (lum 0/255/128 by the sum-256 weights). Row 0 = 8 black + 8 white
            source px -> doubled word 0xFFFF0000 (LSB = LEFTMOST: low 16 bits are
            the black half). Row 1 = 16x gray: Bayer row 1 thresholds
            {200,72,232,104}, 128 beats cols 1,3 -> bit pairs 00 11 00 11 = 0xCC
            per byte -> 0xCCCCCCCC. Each word stored to BOTH output lines (2x2
            doubling). Second pass: same frame, dst = oc+3, stride = -1 — the
            bottom-up flip as the machine uses it, same words mirror-ordered. *)
       , [ 0, 255; 4, 255 ] )
     ; ( "unsigned int env1[9]; int jhelp(int n){ if (n == 0) __longjmp(env1, 42); \
          return jhelp(n - 1) + 1; } int sj1(int i){ int r; int acc; acc = 0; r = \
          __setjmp(env1); acc = acc + 1; if (r == 0) { jhelp(3); return -1; } return r * \
          10 + acc + (i - i); }"
       , "sj1"
         (* __setjmp returns 0 first, then the __longjmp val (42) from 3 calls
            deep. [acc] pins OUR restore semantics: it lives in a home register,
            so the longjmp rewinds it to its setjmp-time value (0) and the
            re-executed increment makes it 1 -> 42*10 + 1. (C calls such locals
            indeterminate; the implementation is allowed to be this.) The
            runner's R6-R11 sentinels also verify the whole unwind preserved
            the entry's callee-saved contract. *)
       , [ 0, 421; 6, 421 ] )
     ; ( "int diver(int n, int s){ if (n == 0) exit(s); return diver(n - 1, s) + 1; } \
          int ext1(int i){ int r; *(volatile int *)(__shared_base + 12) = 0; r = \
          __setjmp(__exit_env); if (r == 0) { diver(4, i); return -1; } return r * 1000 \
          + *(volatile int *)(__shared_base + 12) + (i - i); }"
       , "ext1"
         (* the REAL exit() from 4 calls deep: longjmp val 1, and the §8 status
            mapping — exit(0) writes 1 (clean quit), nonzero passes through
            (I_Error's -1 stays negative): 1000 + status *)
       , [ 0, 1001; 7, 1007; -3, 997 ] )
     ; ( "typedef struct _IO_FILE FILE; extern FILE *fopen(const char *, const char *); \
          extern unsigned long fread(void *, unsigned long, unsigned long, FILE *); \
          unsigned char wadbuf[16] = {73,87,65,68,1,2,3,4,5,6,7,8,9,10,11,12}; int \
          in1(int i){ FILE *f; unsigned char b[4]; int r; *(volatile unsigned int \
          *)(__shared_base + 28) = 16; r = Init((int)wadbuf, 0); if (r != 0) return -1; \
          f = fopen(\"doom1.wad\", \"rb\"); if (!f) return -2; fread(b, 1, 4, f); return \
          b[0] + b[1] * 1000 + b[3] * 100000 + (i - i); }"
       , "in1"
         (* the REAL Init, happy path (Create faked to a no-op): reads the WAD
            length from SHARED +28, registers the memory file under the exact
            -iwad name, returns 0; then fopen/fread proves the registration —
            'I'(73) + 'W'(87)*1000 + 'D'(68)*100000 *)
       , [ 0, 6887073; 2, 6887073 ] )
     ; ( "int tk1(int i){ int a; int b; unsigned int hb; *(volatile unsigned int \
          *)(__shared_base + 16) = 0; a = Tick(); b = Tick(); hb = *(volatile unsigned \
          int *)(__shared_base + 16); return a + b * 10 + (int)hb * 100 + (i - i); }"
       , "tk1"
         (* the REAL Tick twice (doomgeneric_Tick faked): returns 0 both times
            and the §8 +16 heartbeat reads 2 *)
       , [ 0, 200; 1, 200 ] )
     ; ( "int ki1(int i){ int p; unsigned char k; int r; KeyIn(173 * 256 + 1); KeyIn(32 \
          * 256); r = 0; if (DG_GetKey(&p, &k)) r = p * 1000 + k; if (DG_GetKey(&p, &k)) \
          r = r * 10000 + p * 1000 + k; if (DG_GetKey(&p, &k)) r = -1; return r + (i - \
          i); }"
       , "ki1"
         (* the REAL KeyIn -> ring -> DG_GetKey round trip: ev = pressed |
            key << 8 — make of 173 then break of 32, drained in order:
            (1*1000+173)*10000 + (0*1000+32) *)
       , [ 0, 11730032; 4, 11730032 ] )
     ]
;;

(* the full-machine-shape witness: DG_DrawFrame itself — the palette_changed
   protocol and the real rect geometry (origin word 583*32+6, stride -32, 400
   lines x 20 words) — against a sentinel-fenced framebuffer. All-black palette:
   the rect goes 0 and the four fence words (left/right/above/below the rect)
   survive; then color 0 -> white, palette_changed re-raised: the rect goes all-1
   through the rebuilt LUT and the flag reads cleared. Two full 320x200 blits
   ~3.5M instrs: its own list, run with an explicit step budget. *)
let port_selfchecks_big =
  [ ( port_prelude
      ^ "unsigned char sbuf[64000]; int kd2(int i){ unsigned int *fb; int k; int r; fb = \
         (unsigned int *)__fb_base; r = 0; DG_ScreenBuffer = sbuf; for (k = 0; k < \
         64000; k++) sbuf[k] = 0; for (k = 0; k < 256; k++) { colors[k].b = 0; \
         colors[k].g = 0; colors[k].r = 0; colors[k].a = 0; } palette_changed = 1; \
         fb[583 * 32 + 5] = 0x12345678u; fb[583 * 32 + 26] = 0x12345678u; fb[584 * 32 + \
         6] = 0x12345678u; fb[183 * 32 + 6] = 0x12345678u; DG_DrawFrame(); r += \
         (palette_changed == 0); r += (fb[583 * 32 + 6] == 0) * 2; r += (fb[184 * 32 + \
         25] == 0) * 4; r += (fb[583 * 32 + 5] == 0x12345678u) * 8; r += (fb[583 * 32 + \
         26] == 0x12345678u) * 16; r += (fb[584 * 32 + 6] == 0x12345678u) * 32; r += \
         (fb[183 * 32 + 6] == 0x12345678u) * 64; colors[0].b = 255; colors[0].g = 255; \
         colors[0].r = 255; palette_changed = 1; DG_DrawFrame(); r += (fb[583 * 32 + 6] \
         == 0xFFFFFFFFu) * 128; r += (fb[184 * 32 + 25] == 0xFFFFFFFFu) * 256; return r \
         + (i - i); }"
    , "kd2"
    , [ 0, 511; 1, 511 ] )
  ]
;;

(* ---- the dither differential: the SAME dither.c — the file that ships in the
   blob — compiles on both sides (ours via ~port, gcc's via gcc_extra), so any
   divergence is a miscompile of the actual shipped kernel. Small frames only
   (a full 320x200 blit is ~1.7M instrs — kd2's job); checksums cross the diff,
   never pointers. ---- *)
let dither_src = In_channel.with_open_text (libc_path "dither.c") In_channel.input_all

let port_diff_samples =
  List.map (fun (src, name, arity) -> port_prelude ^ src, name, arity)
  @@ [ ( "unsigned char dpal[1024]; unsigned char dfr[64]; unsigned int dob[8]; int \
          dd1(int a){ int i; unsigned int s; for (i = 0; i < 256; i++) { dpal[4 * i] = \
          i; dpal[4 * i + 1] = (i * 3) & 255; dpal[4 * i + 2] = (i * 7) & 255; dpal[4 * \
          i + 3] = 0; } __dg_build_lut(dpal); for (i = 0; i < 64; i++) dfr[i] = (i * 17 \
          + (a & 0xFFFF)) & 255; __dg_dither(dfr, 16, 4, dob, 1); s = 0; for (i = 0; i < \
          8; i++) s = s * 31 + dob[i]; return s; }"
       , "dd1"
       , 1 (* LUT + dither over an arg-seeded 16x4 frame, all four Bayer rows *) )
     ; ( "unsigned char epal[1024]; unsigned char efr[128]; unsigned int eob[16]; int \
          dd2(int a){ int i; unsigned int s; for (i = 0; i < 256; i++) { epal[4 * i] = \
          (i * 5) & 255; epal[4 * i + 1] = (255 - i) & 255; epal[4 * i + 2] = (i ^ 99) & \
          255; epal[4 * i + 3] = 0; } __dg_build_lut(epal); for (i = 0; i < 128; i++) \
          efr[i] = (i * 13 + (a & 4095)) & 255; __dg_dither(efr, 32, 4, eob + 14, -2); s \
          = 0; for (i = 0; i < 16; i++) s = s * 31 + eob[i]; return s; }"
       , "dd2"
       , 1
         (* multi-word rows + NEGATIVE stride (the machine's bottom-up shape)
              into a 2-word-wide, 8-line buffer filled from the top end *)
       )
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
let check_sample ?(libc = false) ?(port = false) ?(gcc_extra = "") (src, fname, arity)
  : int * int
  =
  let body, data = dcc_compile ~libc ~port ~src ~fname () in
  let exe = gcc_compile ~gcc_extra ~src ~fname ~arity () in
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
  match dcc_compile ~src ~fname () with
  | exception Check.Unsupported msg ->
    Printf.printf "  reject %-6s ✓ (%s)\n" fname msg;
    0
  | _ ->
    Printf.printf "  reject %-6s ✗ — GATE LEAK: compiled a banned construct\n" fname;
    1
;;

(* one self-check: run ours over the given args, compare to the stated constants *)
let check_self ?(port = false) ?steps (src, fname, cases) : int * int =
  let body, data = dcc_compile ~libc:true ~port ~src ~fname () in
  let sfails = ref 0 in
  List.iter
    (fun (arg, want) ->
       let got = u32 (Runner.run ~data ?steps body [ arg ]) in
       if got <> u32 want
       then (
         incr sfails;
         Printf.printf "  SELFCHECK %s(%d): got %08x want %08x\n" fname arg got want))
    cases;
  Printf.printf
    "  %-7s %d instr, %d cases%s (self)\n"
    fname
    (List.length body)
    (List.length cases)
    (if !sfails = 0 then "  ok" else Printf.sprintf "  %d FAIL" !sfails);
  List.length cases, !sfails
;;

let () =
  Random.init 0x51ce;
  let fold libc (cases, fails) list =
    List.fold_left
      (fun (cases, fails) sample ->
         let c, f = check_sample ~libc sample in
         cases + c, fails + f)
      (cases, fails)
      list
  in
  let fixed_fold acc =
    List.fold_left
      (fun (cases, fails) sample ->
         let c, f = check_sample ~libc:true ~gcc_extra:fixed_ref sample in
         cases + c, fails + f)
      acc
      fixed_samples
  in
  let dither_fold acc =
    List.fold_left
      (fun (cases, fails) sample ->
         let c, f = check_sample ~libc:true ~port:true ~gcc_extra:dither_src sample in
         cases + c, fails + f)
      acc
      port_diff_samples
  in
  let self_fold ?port ?steps acc list =
    List.fold_left
      (fun (cases, fails) sc ->
         let c, f = check_self ?port ?steps sc in
         cases + c, fails + f)
      acc
      list
  in
  let total, sample_fails =
    self_fold
      ~port:true
      ~steps:8_000_000
      (self_fold
         ~port:true
         (self_fold
            (dither_fold
               (fixed_fold (fold true (fold false (0, 0) samples) libc_samples)))
            libc_selfchecks)
         port_selfchecks)
      port_selfchecks_big
  in
  let fails =
    sample_fails + List.fold_left (fun acc r -> acc + check_reject r) 0 rejects
  in
  Printf.printf
    "diff jig: %d run cases across %d samples + %d gate rejects, %d failures\n"
    total
    (List.length samples
     + List.length libc_samples
     + List.length fixed_samples
     + List.length port_diff_samples
     + List.length libc_selfchecks
     + List.length port_selfchecks
     + List.length port_selfchecks_big)
    (List.length rejects)
    fails;
  if fails > 0 then exit 1
;;
