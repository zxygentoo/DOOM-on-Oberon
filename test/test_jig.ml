(* The differential jig: compile small C samples with our backend, run them in the
   emulator, and diff R0 against host gcc over edge and random int args. Samples keep
   their memory inside, so the harness stays int-in/int-out; both sides get fresh global
   state per run. Authoring rules: (1) loop samples mask their trip count, so full-range
   args can't spin; (2) never let a raw pointer value reach a result or comparison — the
   emulator and the host are different address spaces, so only dereferenced values and
   pointer differences compare. *)

open Doomcc_core

let u32 x = x land 0xFFFF_FFFF

(* the mini-libc, merged into a sample as doomcc merges it with the tree; the gcc side
   never sees it, so our memcpy diffs against the real glibc. The path list covers dune's
   two working directories (exec and runtest). *)
let libc_path name =
  List.find Sys.file_exists [ "libc/" ^ name; "../libc/" ^ name; "../../libc/" ^ name ]
;;

(* Stand-ins for doomgeneric_Create/Tick, which the real tree defines but the libc-only
   merge doesn't, so the real Init/Tick entries run in the emulator. The fake Create must
   not call DG_Init: its banner printf would spin on a UART tx-ready bit the bare emulator
   never raises. *)
let port_fakes =
  "int __fake_argc; char __fake_a3; char __fake_a4; unsigned char *__dg_fixed_vbuf; void \
   doomgeneric_Tick(void) { } void doomgeneric_Create(int argc, char **argv) { \
   __fake_argc = argc; __fake_a3 = argc > 3 ? argv[3][0] : 0; __fake_a4 = argc > 4 ? \
   argv[4][4] : 0; }"
;;

(* our side: parse, place globals, compile and link, once per sample; returns the code and
   the data/bss image *)
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
           [ Frontend.parse_file (libc_path "doom_oberon.c")
           ; Frontend.parse_file (libc_path "dither.c")
           ; Frontend.parse_string ~name:"port_fakes" port_fakes
           ]
         else [])
        ~name:fname
    else file
  in
  let globals = Globals.from_file file in
  (* the entry links first, at offset 0 where the Runner starts; the runtime helpers link
     into every program, as in the blob *)
  let objs = List.map (Fundec.compile ~globals) (Frontend.fundecs file) in
  (* the drawer swap, as in doomcc: a sample that links dither.c runs the hand-written
     drawers, diffed against gcc compiling the C *)
  let objs =
    let off name = Globals.offset_of_name globals file name in
    let str l = Hashtbl.find_opt globals.Globals.strings l in
    let drawers =
      List.filter
        (fun (d : Linker.obj) ->
           List.exists (fun (o : Linker.obj) -> o.Linker.name = d.Linker.name) objs)
        (Drawers.build ~off ~str)
    in
    if drawers = []
    then objs
    else (
      let names = List.map (fun (d : Linker.obj) -> d.Linker.name) drawers in
      List.filter (fun (o : Linker.obj) -> not (List.mem o.Linker.name names)) objs
      @ drawers)
  in
  let entry, rest = List.partition (fun o -> o.Linker.name = fname) objs in
  let image =
    Linker.link ~code_base:(Runner.code_base * 4) (entry @ rest @ Runtime.objs)
  in
  (* patch the pointer-initializer relocs now that both bases are fixed *)
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

(* the gcc oracle: the sample plus an argv driver, compiled once, run per tuple *)
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
  (* The oracle models our target, not the x86-64 host: -m32 because RISC5 is ILP32 (int,
     long and pointers 32-bit), -funsigned-char because ABI §1 makes char unsigned. *)
  let cmd =
    Printf.sprintf
      "gcc -std=gnu99 -m32 -funsigned-char -w -O0 %s -o %s"
      (Filename.quote cfile)
      (Filename.quote exe)
  in
  if Sys.command cmd <> 0
  then
    failwith
      ("gcc failed for "
       ^ fname
       ^ " (the oracle builds with -m32: is the 32-bit multilib installed? `make \
          prereqs` checks)");
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

(* (source, entry function, arity) *)
let samples =
  [ (* straight-line integer ops *)
    "int add(int a,int b){ return a+b; }", "add", 2
  ; "int sub(int a,int b){ return a-b; }", "sub", 2
  ; "int mul(int a,int b){ return a*b; }", "mul", 2
  ; "int bitops(int a,int b){ return (a & b) | (a ^ b); }", "bitops", 2
  ; "int shl(int a){ return a << 3; }", "shl", 1
  ; "int sar(int a){ return a >> 1; }", "sar", 1
  ; "int mix(int a,int b,int c){ int t = a*b; return t - c + 7; }", "mix", 3
  ; "int bigc(int a){ return a + 100000; }", "bigc", 1 (* past a 16-bit immediate *)
  ; "int negx(int a){ return -a; }", "negx", 1
  ; "int notx(int a){ return ~a; }", "notx", 1 (* control flow *)
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
    (* loops (trip counts masked so full-range args terminate) *)
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
    (* globals *)
  ; "int gi = 42; int grd(int x){ return gi + x; }", "grd", 1
  ; "int gz; int rz(int x){ return gz + x; }", "rz", 1 (* no initializer: the bss *)
  ; "int gw; int gwr(int x){ gw = x * 2; return gw + 1; }", "gwr", 1
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
    (* the address calculus: arrays, structs, deref *)
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
    (* pointer arithmetic *)
  ; ( "int a4[8] = {2,4,6,8,10,12,14,16}; int pa(int i){ int *q = a4 + (i & 7); return \
       *q; }"
    , "pa"
    , 1 )
  ; ( "int ae[8] = {2,4,6,8,10,12,14,16}; int pm(int i){ int *q = ae + 7; return *(q - \
       (i & 7)); }"
    , "pm"
    , 1 )
  ; ( "int ad[8]; int pd(int i){ int *p = ad + (i & 7); int *q = ad + 2; return p - q; }"
    , "pd"
    , 1 (* pow-2 ptr - ptr: ASR *) )
  ; ( "int aw[8] = {1,2,3,4,5,6,7,8}; int wsum(int n){ n &= 7; int *q = aw; int s = 0; \
       int i = 0; for (i = 0; i < n; i++){ s += *q; q = q + 1; } return s; }"
    , "wsum"
    , 1 )
  ; ( "int af[8] = {1,2,3,4,5,6,7,8}; int walkne(int n){ n &= 7; int *q = af; int *end = \
       af + n; int s = 0; while (q != end){ s += *q; q = q + 1; } return s; }"
    , "walkne"
    , 1 )
    (* char: LDB/STB and narrowing *)
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
    (* short and signed char: halfwords composed from two bytes, signed vs unsigned
       widening *)
  ; "short gs = 1000; int rs(int x){ return gs + x; }", "rs", 1
  ; ( "short gn = -5; int rn(int x){ return gn + x; }"
    , "rn"
    , 1 (* negative: sign-extend on the composed load *) )
  ; ( "unsigned short us = 50000; int ru(int x){ return us + x; }"
    , "ru"
    , 1 (* > 32767: zero-extended, NOT sign-extended *) )
  ; "signed char sc = -1; int rsc(int x){ return sc + x; }", "rsc", 1
  ; "short sar[4] = {100,-200,300,-400}; int sget(int i){ return sar[i & 3]; }", "sget", 1
  ; ( "struct sm { int a; short b; }; struct sm sm0 = {1000, -50}; int smf(int k){ \
       return sm0.a + sm0.b * k; }"
    , "smf"
    , 1 )
  ; ( "short sw; int sset(int x){ sw = x; return sw; }"
    , "sset"
    , 1 (* composed store (2×STB) then signed read-back: (short)40000 = -25536 *) )
  ; ( "unsigned short uw; int uset(int x){ uw = x; return uw; }"
    , "uset"
    , 1 (* unsigned read-back: (unsigned short)70000 = 4464 *) )
  ; "int ps(short s){ return s; }", "ps", 1 (* signed short param: sign-extend at entry *)
  ; "int psc(signed char c){ return c; }", "psc", 1
  ; "int scast(int x){ short s = x; return s; }", "scast", 1
    (* the callee frame: enough live values to reach callee-saved R6-R9; the Runner's
       sentinels check the save/restore *)
  ; ( "int regpress(int x){ int a=x+1,b=x+2,c=x+3,d=x+4,e=x+5,f=x+6; return a*b + c*d + \
       e*f + a - f; }"
    , "regpress"
    , 1 )
    (* calls *)
  ; "int g(int x){ return x + 1; } int f(int x){ return g(x) * 2; }", "f", 1
  ; ( "int add3(int a,int b,int c){ return a + b + c; } int u3(int x){ return add3(x, x \
       + 1, x + 2); }"
    , "u3"
    , 1 )
  ; ( "int add4(int a,int b,int c,int d){ return a + b + c + d; } int u4(int x){ return \
       add4(x, x + 1, x + 2, x + 3); }"
    , "u4"
    , 1 )
  ; ( "int sq(int x){ return x * x; } int ss(int x){ return sq(x) + sq(x + 1); }"
    , "ss"
    , 1 (* two calls; the first result is held (a home) across the second *) )
  ; ( "int inc(int x){ return x + 1; } int chain(int x){ int a = x * 3; int b = inc(a); \
       return a + b; }"
    , "chain"
    , 1 (* a is live across the call: its callee-saved home preserves it *) )
  ; ( "int fib(int n){ n &= 7; if (n < 2) return n; return fib(n - 1) + fib(n - 2); }"
    , "fib"
    , 1 )
    (* stack args: a callee with more than four params reads 5+ at FP+16.. *)
  ; "int sum6(int a,int b,int c,int d,int e,int f){ return a+b+c+d+e+f; }", "sum6", 6
  ; ( "int side(int x){ return x; } int nl5(int a,int b,int c,int d,int e){ return \
       side(a) + b + c + d + e; }"
    , "nl5"
    , 5 )
    (* a caller passing more than four args stages 5+ at SP+16..; u6 is position-weighted,
       so a misordered slot shows *)
  ; ( "int add5(int a,int b,int c,int d,int e){ return a+b+c+d+e; } int u5(int x){ \
       return add5(x, x+1, x+2, x+3, x+4); }"
    , "u5"
    , 1 )
  ; ( "int take6(int a,int b,int c,int d,int e,int f){ return a + b*2 + c*3 + d*4 + e*5 \
       + f*6; } int u6(int x){ return take6(x, x+1, x+2, x+3, x+4, x+5); }"
    , "u6"
    , 1 )
  ; ( "int add5(int a,int b,int c,int d,int e){ return a+b+c+d+e; } int both5(int a,int \
       b,int c,int d,int e){ return add5(e,d,c,b,a) + a; }"
    , "both5"
    , 5
      (* both directions in one frame: its own stack param (FP+16) and an outgoing stack
         arg (SP+16); the reversed order surfaces a misplaced slot *)
    )
    (* frame slots: aggregates and address-taken scalars. Every slot is written before it
       is read — our garbage isn't gcc's garbage. *)
  ; "int aql(int x){ int y = x; int *p = &y; *p = *p + 3; return y; }", "aql", 1
  ; ( "int larr(int i){ int t[4]; t[0]=5; t[1]=6; t[2]=7; t[3]=8; return t[i & 3]; }"
    , "larr"
    , 1 )
  ; ( "struct ls { int a; int b; }; int lstruct(int k){ struct ls p; p.a = k; p.b = k + \
       1; return p.a * p.b; }"
    , "lstruct"
    , 1 )
  ; "int cptr(int x){ char c = x; char *p = &c; *p = *p + 1; return c; }", "cptr", 1
  ; ( "int addone(int *p){ *p = *p + 1; return 0; } int outp(int x){ int y = x; \
       addone(&y); return y; }"
    , "outp"
    , 1 (* &local escaping to a callee: slot and outgoing area coexist *) )
    (* address-taken params keep their register home; the prologue spills it to the slot *)
  ; "int aptr(int x){ int *p = &x; *p = *p + 5; return x; }", "aptr", 1
  ; ( "int amid(int a,int b,int c){ int *p = &b; return a + *p * 10 + c * 100; }"
    , "amid"
    , 3
      (* the middle param is slotted, position-weighted so a disturbed placement surfaces *)
    )
  ; ( "int addfive(int *p){ *p = *p + 5; return 0; } int outparam(int x){ addfive(&x); \
       return x; }"
    , "outparam"
    , 1 )
    (* whole-struct copies (byte-wise): each writes fields, copies, reads back *)
  ; ( "struct s2 { int a; int b; }; int cps(int x){ struct s2 p, q; p.a = x; p.b = x + \
       1; q = p; return q.a * 10 + q.b; }"
    , "cps"
    , 1 )
  ; ( "struct s2 { int a; int b; }; int cpp(int x){ struct s2 p, q; struct s2 *sp = &p; \
       struct s2 *dp = &q; p.a = x; p.b = x + 3; *dp = *sp; return q.a * 2 + q.b; }"
    , "cpp"
    , 1 )
  ; ( "struct sh { short x; short y; short z; }; int cpsh(int a){ struct sh p, q; p.x = \
       a; p.y = a + 1; p.z = a + 2; q = p; return q.x + q.y * 100 + q.z * 10000; }"
    , "cpsh"
    , 1 (* 6 bytes, align 2: the non-word size and sub-word address LDW/STW would mask *)
    )
  ; ( "struct s2 { int a; int b; }; int cparr(int i){ i &= 1; struct s2 arr[2]; arr[0].a \
       = 10; arr[0].b = 20; arr[1].a = 30; arr[1].b = 40; struct s2 t; t = arr[i]; \
       return t.a + t.b; }"
    , "cparr"
    , 1 )
  ; ( "struct sc { int a; int b; }; struct sc s1 = {1, 2}; struct sc s2; int cpg(int x){ \
       s2 = s1; return s2.a + x; }"
    , "cpg"
    , 1 )
    (* comparisons and ! as 0/1 values; full-range args (INT_MIN/MAX) catch a flipped
       condition through SUB overflow *)
  ; "int ltv(int a,int b){ return a < b; }", "ltv", 2
  ; "int gtv(int a,int b){ return a > b; }", "gtv", 2
  ; "int lev(int a,int b){ return a <= b; }", "lev", 2
  ; "int gev(int a,int b){ return a >= b; }", "gev", 2
  ; "int eqv(int a,int b){ return a == b; }", "eqv", 2
  ; "int nev(int a,int b){ return a != b; }", "nev", 2
  ; "int lnot(int x){ return !x; }", "lnot", 1
  ; "int notnot(int x){ return !!x; }", "notnot", 1
  ; "int cmix(int a,int b){ return (a > b) * 100 + (a < b) * 10 + (a == b); }", "cmix", 2
    (* unsigned ordered compares read the carry; equal-pair edges can't tell signed from
       unsigned, so uhi pins it *)
  ; "int ultv(unsigned a,unsigned b){ return a < b; }", "ultv", 2
  ; "int ulev(unsigned a,unsigned b){ return a <= b; }", "ulev", 2
  ; "int ugtv(unsigned a,unsigned b){ return a > b; }", "ugtv", 2
  ; "int ugev(unsigned a,unsigned b){ return a >= b; }", "ugev", 2
  ; ( "int uhi(unsigned a){ return a < 0x80000000u; }"
    , "uhi"
    , 1
      (* deterministic signed/unsigned distinguisher: a=1 → 1 unsigned, 0 if wrongly signed *)
    )
  ; ( "int uc(unsigned a,unsigned b){ if (a < b) return 1; return 0; }"
    , "uc"
    , 2 (* unsigned compare as a condition (gen_cond) *) )
  ; ( "int pcmp(int i,int j){ int a[8]; int *p = &a[i & 7]; int *q = &a[j & 7]; return p \
       < q; }"
    , "pcmp"
    , 2 (* pointer < (CIL lowers it to unsigned); only the 0/1 escapes *) )
    (* logical >>: the x = -1 edge separates it from ASR; n = 1, 16, 31 span the mask
       cases (load_const, immediate, one bit) *)
  ; "unsigned usr1(unsigned x){ return x >> 1; }", "usr1", 1
  ; "unsigned usr16(unsigned x){ return x >> 16; }", "usr16", 1
  ; "unsigned usr31(unsigned x){ return x >> 31; }", "usr31", 1
  ; "unsigned usrmix(unsigned a){ return (a >> 8) & 0xFF; }", "usrmix", 1
    (* switch: dispatch chain, fall-through, break, default (x masked onto real cases) *)
  ; ( "int sw1(int x){ x &= 3; int r = 0; switch (x) { case 0: r = 10; break; case 1: r \
       = 20; break; case 2: r = 30; break; default: r = 99; } return r; }"
    , "sw1"
    , 1 )
  ; ( "int swf(int x){ x &= 3; int r = 0; switch (x) { case 0: r += 1; case 1: r += 10; \
       case 2: r += 100; break; default: r = 999; } return r; }"
    , "swf"
    , 1 )
  ; ( "int swd(int x){ x &= 7; switch (x) { case 1: case 2: return 12; case 5: return 5; \
       default: return 0; } }"
    , "swd"
    , 1 )
  ; ( "int swnb(int x){ x &= 3; int r = 7; switch (x) { case 1: r = 100; break; case 2: \
       r = 200; break; } return r; }"
    , "swnb"
    , 1 )
    (* continue and goto. CIL lowers a for-loop continue to a goto before the increment. *)
  ; ( "int wc(int n){ n &= 15; int s = 0, i = 0; while (i < n) { i++; if (i == 3) \
       continue; s += i; } return s; }"
    , "wc"
    , 1 )
  ; ( "int fc(int n){ n &= 7; int s = 0, i = 0; for (i = 0; i < n; i++) { if (i == 2) \
       continue; s += i; } return s; }"
    , "fc"
    , 1 )
  ; ( "int gt(int x){ int s = 0; if (x < 0) goto done; s = x * 2; done: return s + 1; }"
    , "gt"
    , 1 )
  ; ( "int gtb(int n){ n &= 7; int s = 0, i = 0; top: if (i < n) { s += i; i++; goto \
       top; } return s; }"
    , "gtb"
    , 1 )
    (* spilling: more than six register variables in a non-leaf, all live across a call;
       the result folds in every one, so a dropped or aliased spill shows *)
  ; ( "int addc(int x, int y){ return x + y; } int many(int a, int b){ int t0 = a, t1 = \
       a + b, t2 = a - b, t3 = a * 2, t4 = b * 2, t5 = a + 1, t6 = b + 1, t7 = a ^ b, t8 \
       = a & b, t9 = a | b; int s = addc(t0, t1); return s + t2 + t3 + t4 + t5 + t6 + t7 \
       + t8 + t9; }"
    , "many"
    , 2 )
  ; ( "int idc(int x){ return x; } int sloop(int n){ n &= 7; int a = 1, b = 2, c = 3, d \
       = 4, e = 5, f = 6, g = 7, h = 8; int i = 0, s = 0; for (i = 0; i < n; i++){ s += \
       idc(a + b + c + d + e + f + g + h) + i; } return s; }"
    , "sloop"
    , 1 (* spilled locals live across a call inside a loop *) )
  ; ( "int rd(int *p){ return *p; } int mixs(int a, int b){ int box = a * 3; int t0 = a, \
       t1 = b, t2 = a + b, t3 = a - b, t4 = a | b, t5 = a & b, t6 = a ^ b, t7 = a + 1; \
       int s = rd(&box); return s + t0 + t1 + t2 + t3 + t4 + t5 + t6 + t7; }"
    , "mixs"
    , 2 (* an address-taken slot and spill slots share the locals region *) )
    (* sizeof folds to a constant; each result adds x so the fold is a real value. The
       host's 64-bit size_t truncates to the same 32 bits. *)
  ; "int szint(int x){ return sizeof(int) + x; }", "szint", 1
  ; ( "int szptr(int x){ return sizeof(int *) + x; }"
    , "szptr"
    , 1 (* a pointer is 4 bytes (ABI §1) *) )
  ; ( "struct pt3 { int a; int b; }; int szst(int x){ return sizeof(struct pt3) + x; }"
    , "szst"
    , 1 )
  ; ( "int szarr(int x){ int a[10]; return sizeof(a) + x; }"
    , "szarr"
    , 1 (* sizeof an array lvalue: the operand is never evaluated *) )
  ; "int szstr(int x){ return sizeof(\"hello\") + x; }", "szstr", 1
    (* string literals: only the bytes compare across address spaces, so every sample
       dereferences *)
  ; "int sidx(int i){ char *s = \"ABCD\"; return s[i & 3]; }", "sidx", 1
  ; ( "int slen(int i){ char *s = \"hello\"; int n = 0; while (s[n]) n++; return n + i; }"
    , "slen"
    , 1 (* iterate to the NUL: proves it is placed *) )
  ; ( "int rdc(char *p, int i){ return p[i]; } int spass(int i){ return rdc(\"WXYZ\", i \
       & 3); }"
    , "spass"
    , 1 (* a literal as a call argument (the printf shape) *) )
  ; ( "int smulti(int i){ char *a = \"AB\", *b = \"cd\"; return a[i & 1] + b[i & 1]; }"
    , "smulti"
    , 1 )
    (* division: / and % call the runtime helpers. All four sign combinations, both
       operators; operands masked so nothing divides by zero or computes INT_MIN / -1 (UB,
       and gcc traps). *)
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
      (* INT_MIN divisor: the helpers' special case (-INT_MIN wraps); a|1 is odd, never
         INT_MIN *)
    )
  ; "int dhalf(int a){ return a / 2; }", "dhalf", 1
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
    , 1 (* non-pow-2 ptr - ptr (12-byte elements) through __div *) )
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
      (* nested divisions: the inner call's use of the div area completes before the
         outer's begins *)
    )
    (* global initializers: pointer-valued ones become relocs, patched here at
       Runner.data_base; typed NULL (a cast of a cast) and double expressions under an int
       cast fold to plain words *)
  ; ( "char *msg = \"hey\"; int spi(int i){ return msg[i & 2]; }"
    , "spi"
    , 1 (* string-pointer initializer, read through the pointer *) )
  ; ( "char *msg2 = \"hi\"; int sl(int x){ if (msg2) return x; return 1; }"
    , "sl"
    , 1 (* the reloc'd pointer is non-null *) )
  ; "int gx = 7; int *gp = &gx; int rp(int i){ return *gp + i; }", "rp", 1
  ; ( "int gx2 = 1; int *gp2 = &gx2; int wp(int i){ *gp2 = i * 3; return gx2; }"
    , "wp"
    , 1 (* write through the reloc'd pointer, read the target — real aliasing *) )
  ; ( "int garr[4] = {10,20,30,40}; int *gpa = garr; int ra(int i){ return gpa[i & 3]; }"
    , "ra"
    , 1 )
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
    , 1 )
  ; ( "char *np = (void *)0; int nul(int i){ if (np) return 0; return i; }"
    , "nul"
    , 1 (* typed NULL: a cast of a cast *) )
  ; ( "typedef int fixed_t; fixed_t sc = (fixed_t)(.867 * (double)65536); int fxc(int \
       i){ return sc + i; }"
    , "fxc"
    , 1 (* the automap-table shape: compile-time double math, C-truncating cast → 56819 *)
    )
  ; ( "typedef int fixed_t; fixed_t nsc = (fixed_t)(-.7 * (double)65536); int fxn(int \
       i){ return nsc + i; }"
    , "fxn"
    , 1 (* negative: -45875.2 truncates toward zero → -45875, not floor's -45876 *) )
    (* call result to a memory lval: R0 is claimed while gen_addr runs *)
  ; ( "int cgv; int idg(int x){ return x * 3; } int cres(int i){ cgv = idg(i); return \
       cgv + 1; }"
    , "cres"
    , 1 )
  ; ( "int idp(int x){ return x - 5; } int cptr2(int i){ int x = 0; int *p = &x; *p = \
       idp(i); return x; }"
    , "cptr2"
    , 1 )
  ; ( "struct cpt { int x; int y; }; struct cpt gcp = {3, 0}; int idq(int x){ return x ^ \
       7; } int cfld(int i){ gcp.y = idq(i); return gcp.y + gcp.x; }"
    , "cfld"
    , 1 )
  ; ( "int cga[4]; int ida(int x){ return x + 9; } int cidx(int i){ cga[(i & 0x7FFF) % \
       4] = ida(i); return cga[(i & 0x7FFF) % 4]; }"
    , "cidx"
    , 1
      (* a __mod inside the destination index while R0 holds the result: the protocol
         saves the claimed R0 *)
    )
  ; ( "char cgc; int idc2(int x){ return x; } int cch(int i){ cgc = idc2(i); return cgc; }"
    , "cch"
    , 1 (* sub-word destination: STB truncates, LDB re-widens — mod-256 both sides *) )
  ; ( "int gw(int x){ return x * 1000 + 7; } int cnr(int x){ short s = gw(x); return s; }"
    , "cnr"
    , 1
      (* a call result narrowed into a REGISTER home: correct only because CIL routes
         the conversion through a temporary (tmp = gw(x); s = (short)tmp) — the
         doCollapseCallCast = false pin in Frontend; flipped, s keeps the whole int *)
    )
    (* unions: members at offset 0, size and alignment the max; a static initializer names
       one member, the rest stay zero. Punning through memory is defined here: both sides
       are little-endian and every access is a real load/store. *)
  ; ( "union uv { int i; char c[4]; }; union uv gu; int ur(int i){ gu.i = i; return \
       gu.c[0] + gu.c[1] * 256; }"
    , "ur"
    , 1 )
  ; ( "union uw { int i; short s; }; union uw guw = { 42 }; int uwr(int i){ return guw.i \
       + i; }"
    , "uwr"
    , 1 )
  ; ( "struct th { int x; union { int a; unsigned b; } u; }; struct th gth = { 1, { 2 } \
       }; int thr(int i){ return gth.x + gth.u.a + i; }"
    , "thr"
    , 1 (* a union nested in a struct (the thinker_t/actionf_t shape) *) )
  ; ( "union pu { int *p; char *q; }; int pux = 258; union pu gpu = { &pux }; int \
       upr(int i){ return *gpu.p + gpu.q[0] + i; }"
    , "upr"
    , 1 (* a reloc inside a union initializer; pun via .q (LE low byte = 2) *) )
  ; ( "union uv2 { int i; char c[4]; }; int ulc(int i){ union uv2 v; v.i = i * 5 + 1; \
       return v.c[3]; }"
    , "ulc"
    , 1 (* a union local, punned through its slot *) )
    (* params past six spill via a prologue copy; a big leaf demotes to the split shape
       (the Runner's sentinels check its saves); scratch widens into unused home registers *)
  ; ( "int p7(int a,int b,int c,int d,int e,int f,int g){ return a + b*2 + c*3 + d*4 + \
       e*5 + f*6 + g*7; }"
    , "p7"
    , 7
      (* 7 params in a leaf: g spills (arrives at FP+24); position-weighted so a wrong
         slot shows *)
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
      (* 14 register candidates in a leaf: demoted, 6 homes + 8 spills, saves R6-R11 but
         not LNK *)
    )
  ; ( "int h1(int x){ return x; } int sdeep(int a, int b){ int r = h1(a); return r + \
       ((a+1) + ((b+2) + ((a+3) + ((b+4) + ((a+5) + ((b+6) + (b*a))))))); }"
    , "sdeep"
    , 2 (* 7+ simultaneous temporaries: inside the widened scratch pool *) )
    (* constant double expressions under an int cast fold at compile time; gcc folds the
       same with real doubles *)
  ; ( "int ff1(int x){ return (int)(0.7 * 65536) + x; }"
    , "ff1"
    , 1 (* the AM_LevelInit shape *) )
  ; ( "int ff2(int x){ return (int)(65536 / 1.02) + (int)(1.02 * 65536) + x; }"
    , "ff2"
    , 1 (* the AM_Responder shapes: constant float division and multiplication *) )
  ; ( "int ff3(int x){ return (char)(1.5 * 200) + x; }"
    , "ff3"
    , 1 (* width-exact narrowing through the fold: (char)300 = 44 (char unsigned) *) )
  ; ( "int ff4(int x){ return (int)(-0.7 * 65536) + x; }"
    , "ff4"
    , 1 (* negative: truncates toward zero, -45875 (not floor's -45876) *) )
    (* varargs: callers store every argument to memory, so va_start = FP + 4*n_formals;
       the oracle compiles the same __builtin_* source with gcc's own varargs *)
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
      (* 7 args: the variadic walk crosses the register/stack boundary; position-weighted *)
    )
  ; ( "int vf2(int a, int b, ...){ __builtin_va_list ap; int v; __builtin_va_start(ap, \
       b); v = __builtin_va_arg(ap, int); __builtin_va_end(ap); return a * 100 + b * 10 \
       + v; } int vshift(int i){ return vf2(1, 2, i & 7); }"
    , "vshift"
    , 1 (* two fixed params: the va_start anchor is FP+8, not FP+4 *) )
  ; ( "int gde[16] = { 5, 9, 2, 7, 1, 8, 3, 6, 4, 10, 11, 12, 13, 14, 15, 16 }; int \
       vf(int n, ...){ __builtin_va_list ap; int x; __builtin_va_start(ap, n); x = \
       __builtin_va_arg(ap, int); __builtin_va_end(ap); return gde[0] - (gde[1] - \
       (gde[2] - (gde[3] - (gde[4] - (gde[5] - (gde[6] - (gde[7] - (gde[8] - (gde[9] - \
       (gde[10] - (gde[11] - (gde[12] - (gde[13] - (gde[14] - (gde[15] + \
       x))))))))))))))); } int vflat(int a){ return vf(1, a); }"
    , "vflat"
    , 1
      (* varargs meet the three-address retry: vf's return needs the flattening (16
         levels over memory leaves), and flattening must leave va_arg's &x alone — CIL
         keeps x register-homed, so a hoisted &x asked for a register's address *)
    )
    (* function addresses: &f is an Addr frag, a fn-ptr initializer a Code reloc; an
       indirect call is BL to a register *)
  ; ( "int inc1(int x){ return x + 1; } int (*gf)(int) = inc1; int icall(int i){ return \
       gf(i) * 2; }"
    , "icall"
    , 1 (* fn-ptr global initializer, called through *) )
  ; ( "int dbl2(int x){ return x * 2; } int lcall(int i){ int (*f)(int) = dbl2; return \
       f(i) + 1; }"
    , "lcall"
    , 1 (* &f into a local (Addr frag), then the indirect call *) )
  ; ( "int app(int (*fp)(int), int x){ return fp(x); } int neg1(int x){ return -x; } int \
       cbk(int i){ return app(neg1, i); }"
    , "cbk"
    , 1 (* the callback pattern (DOOM's action functions) *) )
  ; ( "int aone(int x){ return x + 1; } int atwo(int x){ return x + 2; } int \
       (*ftbl[2])(int) = { aone, atwo }; int tcall(int i){ return ftbl[i & 1](i); }"
    , "tcall"
    , 1 (* table dispatch: the states[] actionf_t shape *) )
  ; ( "int s5f(int a,int b,int c,int d,int e){ return a + b*2 + c*3 + d*4 + e*5; } int \
       (*g5)(int,int,int,int,int) = s5f; int ical5(int i){ return g5(i, i+1, i+2, i+3, \
       i+4); }"
    , "ical5"
    , 1 (* indirect call with a 5th (stack) arg: marshalling + claimed R0-R3 + BL reg *) )
    (* bitfields: byte-aligned :8 only — under GCC's LSB-first allocation struct color's
       b/g/r/a are bytes 0-3, one LDB/STB each. bf1 pins the layout itself: fields
       written, raw bytes read back through a char*, so a CIL machdep that disagreed with
       gcc's allocation would show at once. *)
  ; ( "struct color { unsigned int b:8; unsigned int g:8; unsigned int r:8; unsigned int \
       a:8; }; int bf1(int x){ struct color c; unsigned char *p = (unsigned char *)&c; \
       c.b = 1; c.g = 2; c.r = x; c.a = 4; return p[0] + p[1] * 10 + p[2] * 100 + p[3] * \
       1000; }"
    , "bf1"
    , 1 )
  ; ( "struct color { unsigned int b:8; unsigned int g:8; unsigned int r:8; unsigned int \
       a:8; }; int bf2(int x){ struct color c; c.b = 10; c.g = 20; c.r = 30; c.a = 40; \
       c.g = c.g + x; return c.b + c.g * 100 + c.r * 10000 + c.a * 1000000; }"
    , "bf2"
    , 1
      (* read-modify one field: the neighbors are the witnesses (an STW-shaped store would
         clobber them) *)
    )
  ; ( "struct color { unsigned int b:8; unsigned int g:8; unsigned int r:8; unsigned int \
       a:8; }; struct color colors[4]; unsigned char tab[6] = {3,1,4,1,5,9}; int bf3(int \
       i){ int k; for (k = 0; k < 4; k++) { colors[k].a = 0; colors[k].r = tab[k]; \
       colors[k].g = tab[k + 1]; colors[k].b = tab[k + 2]; } return colors[i & 3].r + \
       colors[(i + 1) & 3].g * 100 + colors[2].b * 10000; }"
    , "bf3"
    , 1 (* the I_SetPalette shape *) )
  ; ( "struct color { unsigned int b:8; unsigned int g:8; unsigned int r:8; unsigned int \
       a:8; }; int bf4(int x){ struct color c; c.g = 300; c.b = (x & 4095) * 5; return \
       c.g * 100000 + c.b * 100 + 7; }"
    , "bf4"
    , 1 (* store-truncation: 300 -> 44, and a wide expression narrowed by STB *) )
  ; ( "struct sbf { int v:8; int w:8; }; int bf5(int x){ struct sbf s; s.v = x; s.w = \
       200; return s.v * 1000 + s.w; }"
    , "bf5"
    , 1
      (* signed :8: reads sign-extend; out-of-range stores wrap like gcc's (200 -> -56) *)
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
  ; ( "int usrv(int a, int n){ return (unsigned int)a >> (n & 31); }"
    , "usrv"
    , 2
      (* unsigned >> by a variable count goes to __lsr; full-range a separates logical
         from arithmetic, n & 31 sweeps the n = 0 corner *)
    )
  ; ( "unsigned int rp[4] = { 0x11223344u, 0x55667788u, 0x99aabbccu, 0xddeeff00u }; int \
       padrj(int i){ unsigned int k; unsigned int s; s = 0; for (k = 0; k < 16; k++) { s \
       = s * 31 + ((rp[k / 4] >> ((k % 4) * 8)) & 0xff); } return s + (i - i); }"
    , "padrj"
    , 1
      (* the PadRejectArray byte-extract shape verbatim: __udiv, __umod and
         __lsr composing in one frame through the shared div area *)
    )
    (* three-address flattening: a right-nested chain over memory leaves holds one scratch
       per level, so at 14+ levels no 12-register pool compiles it unflattened — a green
       diff proves the retry ran *)
  ; ( "int gde[16] = { 5, 9, 2, 7, 1, 8, 3, 6, 4, 10, 11, 12, 13, 14, 15, 16 }; int \
       deep1(int a){ return gde[0] - (gde[1] - (gde[2] - (gde[3] - (gde[4] - (gde[5] - \
       (gde[6] - (gde[7] - (gde[8] - (gde[9] - (gde[10] - (gde[11] - (gde[12] - (gde[13] \
       - (gde[14] - (gde[15] + a))))))))))))))); }"
    , "deep1"
    , 1 )
  ; ( "int gdf[16] = { 5, 9, 2, 7, 1, 8, 3, 6, 4, 10, 11, 12, 13, 14, 15, 16 }; int \
       deep2(int a){ return gdf[0] - (gdf[1] - (gdf[2] - (gdf[3] - (gdf[4] - (gdf[5] - \
       (gdf[6] - (gdf[7] - (gdf[8] - (gdf[9] - (gdf[10] - (gdf[11] - (gdf[12] - (gdf[13] \
       / ((a & 7) + 2)))))))))))))); }"
    , "deep2"
    , 1
      (* a DIVISION at the bottom of the chain: flattening must compose with
         the div-area protocol (the helper call gets atomized operands) *)
    )
  ; ( "int gdg[16] = { 5, 9, 2, 7, 1, 8, 3, 6, 4, 10, 11, 12, 13, 14, 15, 16 }; int \
       dh3(int x, int y){ return x * 2 + y; } int deep3(int a){ return dh3(gdg[0] - \
       (gdg[1] - (gdg[2] - (gdg[3] - (gdg[4] - (gdg[5] - (gdg[6] - (gdg[7] - (gdg[8] - \
       (gdg[9] - (gdg[10] - (gdg[11] - (gdg[12] - (gdg[13] - gdg[14]))))))))))))), \
       gdg[15] - (gdg[14] - (gdg[13] - (gdg[12] + a)))); }"
    , "deep3"
    , 1
      (* deep expressions as CALL ARGUMENTS: hoisted temps meet the arg
         marshaller (args must be atoms while R0-R3 are claimed) *)
    )
  ; ( "struct __attribute__((packed)) ph { char pad[0x7FFFF]; short s; }; int hbig(int \
       v){ unsigned char b[2]; struct ph *p = (struct ph *)(b - 0x7FFFF); p->s = v; \
       return p->s + 7 * b[1]; }"
    , "hbig"
    , 1
      (* a halfword at residual exactly 0x7FFFF, the top of the 20-bit mem-op offset:
         its high byte at off + 1 would wrap to -0x80000, so gen_addr keeps one byte of
         headroom and folds this residual into the base. p is aimed so p->s IS b *)
    )
  ; ( "int bpad[20000]; int btab[8]; int biga(int i){ int k; int *p; for (k = 0; k < 8; \
       k++) btab[k] = k * 1000 + 7; p = &btab[i & 7]; return p[0]; }"
    , "biga"
    , 1
      (* &global[variable] as a value past the 16-bit ALU immediate (80 KB pad):
         materialize_addr must build the offset in a register distinct from the base —
         fopen's &__handles[h] once doubled its offset *)
    )
  ; ( "unsigned char stex[4096]; unsigned char scm[256]; unsigned char sfb[1280]; \
       unsigned char *ylookup[204]; int columnofs[324]; int ds_y; int ds_x1; int ds_x2; \
       unsigned char *ds_colormap; unsigned char *ds_source; int ds_xfrac; int ds_yfrac; \
       int ds_xstep; int ds_ystep; void I_Error(const char *f, ...) { (void)f; } void \
       R_DrawSpan(void) { unsigned int position, step; unsigned char *dest; int count; \
       int spot; unsigned int xtemp, ytemp; if (ds_x2 < ds_x1 || ds_x1 < 0 || ds_x2 >= \
       320 || (unsigned)ds_y > 200) { I_Error(\"R_DrawSpan: %i to %i at %i\", ds_x1, \
       ds_x2, ds_y); } position = ((ds_xfrac << 10) & 0xffff0000) | ((ds_yfrac >> 6) & \
       0x0000ffff); step = ((ds_xstep << 10) & 0xffff0000) | ((ds_ystep >> 6) & \
       0x0000ffff); dest = ylookup[ds_y] + columnofs[ds_x1]; count = ds_x2 - ds_x1; do { \
       ytemp = (position >> 4) & 0x0fc0; xtemp = (position >> 26); spot = xtemp | ytemp; \
       *dest++ = ds_colormap[ds_source[spot]]; position += step; } while (count--); } \
       int spanj(int i) { int k; int s; for (k = 0; k < 4096; k++) stex[k] = (unsigned \
       char)(k * 13 + i); for (k = 0; k < 256; k++) scm[k] = (unsigned char)(255 - k + \
       (i & 7)); for (k = 0; k < 1280; k++) sfb[k] = 0; for (k = 0; k < 204; k++) \
       ylookup[k] = sfb + ((k & 3) * 320); for (k = 0; k < 324; k++) columnofs[k] = k; \
       ds_y = i & 127; ds_x1 = (i >> 3) & 63; ds_x2 = ds_x1 + ((i >> 9) & 31); \
       ds_colormap = scm; ds_source = stex; ds_xfrac = (i & 0xFFFFF) * 3; ds_yfrac = (i \
       & 0xFFFFF) * 5 + 7; ds_xstep = (i & 1023) - 512; ds_ystep = ((i >> 2) & 1023) - \
       256; R_DrawSpan(); s = 0; for (k = 0; k < 1280; k++) s = s * 31 + sfb[k]; return \
       s; }"
    , "spanj"
    , 1
      (* R_DrawSpan: the hand drawer (swapped in because the sample defines every ds_*
         symbol) vs gcc compiling the same .i body; random fracs and steps, spans up to 32
         px, whole-buffer hash *)
    )
  ; ( "unsigned char ctex[128]; unsigned char ccm[256]; unsigned char cfb[1280]; \
       unsigned char *ylookup[204]; int columnofs[324]; int dc_x; int dc_yl; int dc_yh; \
       int dc_iscale; int dc_texturemid; unsigned char *dc_colormap; unsigned char \
       *dc_source; int centery; void I_Error(const char *f, ...) { (void)f; } void \
       R_DrawColumn(void) { int count; unsigned char *dest; int frac; int fracstep; \
       count = dc_yh - dc_yl; if (count < 0) return; if ((unsigned)dc_x >= 320 || dc_yl \
       < 0 || dc_yh >= 200) I_Error(\"R_DrawColumn: %i to %i at %i\", dc_yl, dc_yh, \
       dc_x); dest = ylookup[dc_yl] + columnofs[dc_x]; fracstep = dc_iscale; frac = \
       dc_texturemid + (dc_yl - centery) * fracstep; do { *dest = \
       dc_colormap[dc_source[(frac >> 16) & 127]]; dest += 320; frac += fracstep; } \
       while (count--); } int colj(int i) { int k; int s; for (k = 0; k < 128; k++) \
       ctex[k] = (unsigned char)(k * 29 + i); for (k = 0; k < 256; k++) ccm[k] = \
       (unsigned char)(k * 7 + (i & 15)); for (k = 0; k < 1280; k++) cfb[k] = 0; for (k \
       = 0; k < 204; k++) ylookup[k] = cfb + ((k & 3) * 320); for (k = 0; k < 324; k++) \
       columnofs[k] = k & 255; dc_yl = i & 63; dc_yh = dc_yl + ((i >> 6) & 3); dc_x = (i \
       >> 8) & 255; dc_iscale = (i & 0x3FFFF) - 0x20000; dc_texturemid = (i >> 1) & \
       0xFFFFF; centery = 100; dc_colormap = ccm; dc_source = ctex; R_DrawColumn(); s = \
       0; for (k = 0; k < 1280; k++) s = s * 31 + cfb[k]; return s; }"
    , "colj"
    , 1 (* R_DrawColumn: the hand drawer vs gcc on the same .i body; both iscale signs *)
    )
  ]
;;

(* Each must refuse, for the reason its third field names (a substring of the message).
   Rejects only compile, never run, so they may take pointers. *)
let rejects =
  [ "float f(float x){ return x; }", "f", "float"
  ; "long long g(long long x){ return x + 1; }", "g", "64-bit"
  ; ( "struct pt { int x; int y; }; extern struct pt mk(int); int usemk(int x){ struct \
       pt p = mk(x); return p.x; }"
    , "usemk"
    , "aggregate return" )
  ; ( "extern int ext; int rex(int x){ return ext + x; }"
    , "rex"
    , "extern global without a definition" )
  ; ( "struct t3 { unsigned int v:3; }; int rj3(int x){ struct t3 s; s.v = x; return \
       s.v; }"
    , "rj3"
    , "bitfield" (* a real bitfield (:3) — only the byte-aligned :8 degenerate lowers *) )
  ; ( "struct t48 { unsigned int a:4; unsigned int b:8; }; int rj48(int x){ struct t48 \
       s; s.b = x; return s.b; }"
    , "rj48"
    , "bitfield" (* an :8 pushed off-byte (bit offset 4) — width alone isn't enough *) )
  ; ( "struct t5 { unsigned int v:5; }; int rjp(int x){ return ((struct t5 *)&x)->v; }"
    , "rjp"
    , "bitfield"
      (* a banned bitfield reached through a CAST pointer: no declaration gate ever
         sees struct t5, so this exercises gen_addr/classify_access's own guard *)
    )
  ; ( "int rfr(int i){ char big[70000]; big[i & 0xFFFF] = 1; return big[0]; }"
    , "rfr"
    , "stack frame" )
  ; ( "struct __attribute__((packed)) pk { unsigned char c; int x; }; int rpk(struct pk \
       *p){ return p->x; }"
    , "rpk"
    , "misaligned word access" (* a packed int at +1: LDW would read the word around it *)
    )
  ; ( "struct __attribute__((packed)) pa { int x; char c; }; struct pa ga[2]; int \
       rpa(int i){ ga[1].x = i; return 0; }"
    , "rpa"
    , "misaligned word access"
      (* x is at offset 0 of its struct, but 5-byte elements put ga[1].x at +5: the
         gate reads the whole residual, not the field offset *)
    )
  ; ( "int rbo(int x){ _Bool b = x; return b; }"
    , "rbo"
    , "_Bool" (* (_Bool)256 is 1, not 256 & 0xFF *) )
  ; ( "struct big { char a[600000]; }; int rsc(struct big *d, struct big *s){ *d = *s; \
       return 0; }"
    , "rsc"
    , "struct copy" )
    (* only double constants fold: a float or long double one folded at double precision
       gives the wrong integer *)
  ; ( "int rff(int x){ return (int)16777217.0f + x; }"
    , "rff"
    , "float" (* the float constant IS 16777216.0f: 24-bit significand *) )
  ; ( "int rfc(int x){ return (int)(float)16777217.0 + x; }"
    , "rfc"
    , "float" (* the (float) cast rounds the same way *) )
  ; ( "int rld(int x){ return (int)(9007199254740993.0L - 9007199254740992.0L) + x; }"
    , "rld"
    , "float" (* 1 in long double; 2^53 + 1 isn't a double, so 0 at double precision *) )
  ; ( "int rgv = (int)16777217.0f; int rgi(int x){ return rgv + x; }"
    , "rgi"
    , "float" (* the same fold in a global initializer *) )
  ]
;;

(* mini-libc samples: our libc, compiled by us, against the host's real glibc.
   strcmp-family results are sign-normalized (C leaves the magnitude unspecified); pointer
   results become indexes or flags; the heap globals bind the bump arena in emulator RAM. *)
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
    [ "int mcp(int i){ char b[8]; memcpy(b, \"ABCDEFG\", 8); return b[i & 7]; }", "mcp", 1
    ; ( "int mcpw(int i){ char a[40]; char b[40]; int k; int s; for (k = 0; k < 40; k++) \
         { a[k] = (char)(k * 7 + i); b[k] = (char)(100 - k); } memcpy(b + ((i >> 2) & \
         3), a + (i & 3), 1 + (i & 31)); s = 0; for (k = 0; k < 40; k++) s = s * 31 + \
         b[k]; return s; }"
      , "mcpw"
      , 1
        (* the word-fast-path gate: every src/dst alignment pair x lengths 1..32, hashed
           over the whole dst so overruns and missed tails show *)
      )
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
      , 1 )
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
      , 1 )
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
      , 1 )
      (* the printf core vs glibc's: buffers pre-filled so bytes past the NUL compare,
         results folded as a checksum *)
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
    ; ( "int vsn5(int i){ char b[40]; int k; int s; int r; memset(b, 7, 40); r = \
         snprintf(b, 40, \"[%.3d][%.3d][%.0d][%6.3d][%.2x]\", i & 63, -(i & 63), i & 1, \
         i & 255, i & 255); s = r; for (k = 0; k < 40; k++) s = s * 31 + b[k]; return s; \
         }"
      , "vsn5"
      , 1
        (* integer precision (%.3d — HU_Init's STCFN font names): min digits, sign
           outside, %.0d of 0 prints nothing, precision defeats the zero flag *)
      )
    ; ( "extern const unsigned short **__ctype_b_loc(void); int ct1(int c){ return \
         (int)((*__ctype_b_loc())[c & 255]); }"
      , "ct1"
      , 1
        (* the glibc classification-table protocol: our table vs glibc's, the whole flag
           word per character *)
      )
    ; ( "extern const unsigned short **__ctype_b_loc(void); int ct2(int c){ return \
         (int)((*__ctype_b_loc())[(c & 255) - 128]); }"
      , "ct2"
      , 1
        (* the negative index side, -128..127 — glibc allows isspace(EOF), so
           the table must extend below 0 (all zero in the C locale) *)
      )
    ]
;;

(* m_fixed: FixedMul is the inline intrinsic, FixedDiv libc/fixed.c's restoring division;
   the oracle compiles doomgeneric's real int64_t originals, so our 32-bit machinery meets
   genuine 64-bit arithmetic *)
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
       , 2 (* full-range: a dropped high word shows *) )
     ; ( "extern int FixedMul(int, int); int fxmi(int a){ return FixedMul(a, 1 << 16) - \
          a; }"
       , "fxmi"
       , 1 (* the unit identity: a * 1.0 == a, exact for every a *) )
     ; ( "extern int FixedDiv(int, int); int fxd(int a, int b){ a |= 1; return \
          FixedDiv(a, b); }"
       , "fxd"
       , 2
         (* full-range with a != INT_MIN (the original's abs-overflow quirk diverges
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

(* self-checks against hand-computed constants (the memory-file registry has no glibc
   counterpart). They must not touch the console: the bare emulator has no serial, and the
   tx-ready wait would spin forever. *)
let libc_selfchecks =
  [ ( "char *__heap_base = (char *)0x90000; char *__heap_end = (char *)0xF0000; typedef \
       __builtin_va_list va_list; extern int __setjmp(unsigned int *env); extern void \
       __longjmp(unsigned int *env, int val); unsigned int rje[9]; int ga; int gb; int \
       gc; void I_Error(const char *f, ...) { va_list ap; int a; int b; int c; \
       __builtin_va_start(ap, f); a = __builtin_va_arg(ap, int); b = \
       __builtin_va_arg(ap, int); c = __builtin_va_arg(ap, int); __builtin_va_end(ap); \
       ga = a; gb = b; gc = c; __longjmp(rje, f[0]); } unsigned char *ylookup[204]; int \
       columnofs[324]; int ds_y; int ds_x1; int ds_x2; unsigned char *ds_colormap; \
       unsigned char *ds_source; int ds_xfrac; int ds_yfrac; int ds_xstep; int ds_ystep; \
       void R_DrawSpan(void) { unsigned int position, step; unsigned char *dest; int \
       count; int spot; unsigned int xtemp, ytemp; if (ds_x2 < ds_x1 || ds_x1 < 0 || \
       ds_x2 >= 320 || (unsigned)ds_y > 200) { I_Error(\"R_DrawSpan: %i to %i at %i\", \
       ds_x1, ds_x2, ds_y); } position = ((ds_xfrac << 10) & 0xffff0000) | ((ds_yfrac >> \
       6) & 0x0000ffff); step = ((ds_xstep << 10) & 0xffff0000) | ((ds_ystep >> 6) & \
       0x0000ffff); dest = ylookup[ds_y] + columnofs[ds_x1]; count = ds_x2 - ds_x1; do { \
       ytemp = (position >> 4) & 0x0fc0; xtemp = (position >> 26); spot = xtemp | ytemp; \
       *dest++ = ds_colormap[ds_source[spot]]; position += step; } while (count--); } \
       int rcs(int i){ int r; ds_x1 = 20 + (i & 7); ds_x2 = 3; ds_y = 7; r = \
       __setjmp(rje); if (r) return ((r * 100 + ga) * 100 + gb) * 1000 + gc; \
       R_DrawSpan(); return -1; }"
    , "rcs"
      (* the hand R_DrawSpan's RANGECHECK path (ds_x2 < ds_x1). A variadic callee reads
         its arguments from the caller's home area (ABI §3), so the drawer must store
         them there, not only load R1-R3. The fake I_Error reads all three and longjmps
         out with the format's first byte, 'R' = 82, proving R0 arrived too:
         ((82*100 + ds_x1)*100 + ds_x2)*1000 + ds_y *)
    , [ 0, 822003007; 5, 822503007 ] )
  ; ( "char *__heap_base = (char *)0x90000; char *__heap_end = (char *)0xF0000; typedef \
       __builtin_va_list va_list; extern int __setjmp(unsigned int *env); extern void \
       __longjmp(unsigned int *env, int val); unsigned int rje[9]; int ga; int gb; int \
       gc; void I_Error(const char *f, ...) { va_list ap; int a; int b; int c; \
       __builtin_va_start(ap, f); a = __builtin_va_arg(ap, int); b = \
       __builtin_va_arg(ap, int); c = __builtin_va_arg(ap, int); __builtin_va_end(ap); \
       ga = a; gb = b; gc = c; __longjmp(rje, f[0]); } unsigned char *ylookup[204]; int \
       columnofs[324]; int dc_x; int dc_yl; int dc_yh; int dc_iscale; int dc_texturemid; \
       unsigned char *dc_colormap; unsigned char *dc_source; int centery; void \
       R_DrawColumn(void) { int count; unsigned char *dest; int frac; int fracstep; \
       count = dc_yh - dc_yl; if (count < 0) return; if ((unsigned)dc_x >= 320 || dc_yl \
       < 0 || dc_yh >= 200) I_Error(\"R_DrawColumn: %i to %i at %i\", dc_yl, dc_yh, \
       dc_x); dest = ylookup[dc_yl] + columnofs[dc_x]; fracstep = dc_iscale; frac = \
       dc_texturemid + (dc_yl - centery) * fracstep; do { *dest = \
       dc_colormap[dc_source[(frac >> 16) & 127]]; dest += 320; frac += fracstep; } \
       while (count--); } int rcc(int i){ int r; dc_yl = 5; dc_yh = 9; dc_x = 400 + (i & \
       7); r = __setjmp(rje); if (r) return ((r * 100 + ga) * 100 + gb) * 1000 + gc; \
       R_DrawColumn(); return -1; }"
    , "rcc"
      (* the same for the hand R_DrawColumn (dc_x >= 320):
         ((82*100 + dc_yl)*100 + dc_yh)*1000 + dc_x *)
    , [ 0, 820509400; 5, 820509405 ] )
  ; ( "char *__heap_base = (char *)0x90000; char *__heap_end = (char *)0xF0000; typedef \
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
  ; ( "char *__heap_base = (char *)0x90000; char *__heap_end = (char *)0xF0000; typedef \
       struct _IO_FILE FILE; extern FILE *fopen(const char *, const char *); extern int \
       *__errno_location(void); int er1(int i){ FILE *f; *__errno_location() = 0; f = \
       fopen(\"nope\", \"rb\"); return (f == 0) + (*__errno_location() == 0) * 2 + (i - \
       i); }"
    , "er1"
      (* the M_FileExists shape: a failed fopen leaves errno 0 (this libc never
         sets it), so the tree's errno == EISDIR probe correctly answers "not a
         directory" *)
    , [ 0, 3; 5, 3 ] )
  ]
;;

(* the ~port prelude binds every extern the platform layer reads. __shared_base sits in a
   free 4 KB between the stack top (0x70000) and the data image (0x80000); __fb_base at
   0xC0000. The DOOM-side globals must be defined too: an extern without a definition
   refuses the compile. No console functions (no serial). *)
let port_prelude =
  "char *__heap_base = (char *)0x90000; char *__heap_end = (char *)0xF0000; char \
   *__shared_base = (char *)0x78000; char *__fb_base = (char *)0xC0000; struct color { \
   unsigned int b:8; unsigned int g:8; unsigned int r:8; unsigned int a:8; }; struct \
   color colors[256]; unsigned int palette_changed; unsigned char *DG_ScreenBuffer; \
   extern void DG_KeyEnqueue(int pressed, unsigned char key); extern int DG_GetKey(int \
   *pressed, unsigned char *key); extern unsigned int DG_GetTicksMs(); extern void \
   DG_SleepMs(unsigned int ms); extern void DG_DrawFrame(void); extern void \
   __dg_build_lut(const unsigned char *pal); extern void __dg_dither_fs(const unsigned \
   char *src, unsigned int *dst, int stride); extern int Init(int wad_addr, int \
   cfg_addr); extern int Tick(void); extern void KeyIn(int ev); extern void exit(int \
   status); extern int __setjmp(unsigned int *env); extern void __longjmp(unsigned int \
   *env, int val); extern unsigned int __exit_env[9]; "
;;

(* port self-checks: the key ring, the frame copy and the ms-counter spin (the
   assertion in slp is termination — a frozen clock would spin into the step cap) *)
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
     ; ( "unsigned int fsrc[16000]; unsigned int fdst[16002]; int fcp(int i){ int k; \
          unsigned int h; for (k = 0; k < 16000; k++) fsrc[k] = (unsigned int)k * \
          2654435761u + (unsigned int)i; for (k = 0; k < 16002; k++) fdst[k] = \
          0xA5A5A5A5u; __dg_frame_copy((const unsigned char *)fsrc, (unsigned char \
          *)(fdst + 1)); h = 2166136261u; for (k = 0; k < 16002; k++) h = (h ^ fdst[k]) \
          * 16777619u; return (int)h; }"
       , "fcp"
         (* the hand __dg_frame_copy vs gcc compiling the C: an order-sensitive FNV over
            the whole destination including both fence words *)
       , [ 0, -693980321; 7, 625517663 ] )
     ; ( "int slp(int i){ unsigned int t0; unsigned int t1; t0 = DG_GetTicksMs(); \
          DG_SleepMs(3); t1 = DG_GetTicksMs(); return (t1 - t0 >= 3u) + (i - i); }"
       , "slp"
         (* the spin waits at least [ms] on the Runner's synthetic clock — and
            terminates, which is the assertion a frozen clock would fail *)
       , [ 0, 1; 2, 1 ] )
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
     ; ( "extern int __parse_cmdline(char *s, char **argv, int argc, int max); int \
          pcl1(int i){ char b[32]; char *av[8]; const char *t = \"  -timedemo  demo1\"; \
          int k; int n; int r; for (k = 0; t[k]; k++) b[k] = t[k]; b[k] = 0; n = \
          __parse_cmdline(b, av, 3, 8); r = n; if (av[3][0] == '-' && av[3][1] == 't' && \
          av[3][8] == 'o' && av[3][9] == 0) r = r + 10; if (av[4][0] == 'd' && av[4][4] \
          == '1' && av[4][5] == 0) r = r + 100; return r + (i - i); }"
       , "pcl1"
         (* the tokenizer alone: leading/multiple blanks skipped, two tokens
            appended after the baked 3 (n = 5), each NUL-terminated in place —
            5 + 10 + 100 *)
       , [ 0, 115; 9, 115 ] )
     ; ( "extern int __fake_argc; extern char __fake_a3; extern char __fake_a4; unsigned \
          char wb2[8] = {1,2,3,4,5,6,7,8}; int pcl2(int i){ char *tail; const char *t = \
          \"-timedemo demo1\"; int k; int e0; int e1; int r; tail = __shared_base + \
          1024; *(volatile unsigned int *)(__shared_base + 28) = 8; tail[0] = 0; r = \
          Init((int)wb2, 0); if (r != 0) return -1; e0 = __fake_argc; for (k = 0; t[k]; \
          k++) tail[k] = t[k]; tail[k] = 0; r = Init((int)wb2, 0); if (r != 0) return \
          -2; e1 = __fake_argc; return e0 * 10000 + e1 * 100 + (__fake_a3 == '-') * 10 + \
          (__fake_a4 == '1') + (i - i); }"
       , "pcl2"
         (* the REAL Init end to end (Create faked to a recorder): an empty
            SHARED tail keeps argc = 3; the written tail reaches Create as
            argc = 5 with argv[3] = -timedemo, argv[4] = demo1 (its [4] = '1')
            — 3*10000 + 5*100 + 10 + 1 *)
       , [ 0, 30511; 3, 30511 ] )
     ]
;;

(* the full-machine witness: DG_DrawFrame itself — the palette_changed protocol and the
   real fullscreen geometry (screen top-left = fb word 767*32, stride -32, all 32x768
   words written); fences sit outside the panel (fb[-1], fb[768*32]). All-black palette:
   the panel goes 0, the fences survive; then color 0 -> white with palette_changed
   raised: all ones through the rebuilt LUT, the flag cleared. Two full blits: its own
   list, with an explicit step budget. kdf pins the fullscreen kernel's semantics in two
   passes. Pass 1, endpoints only (lum 0 never fires, 255 always): the 3/3/3/3/4 slot
   masks (white source px 0/4/9 -> word 0xF000F007, LSB leftmost), the Bresenham 3-vs-4
   line dealing (source line 0 -> 3 output lines, line 1 -> 4), and the stride-as-flip
   contract at -32. Pass 2, a mid-tone: a source line's replicated rows alternate between
   bn rows 2*sy and 2*sy+1 — a gray-50 px (gray maps to itself under any sum-256 weights)
   over bn rows 0/1, cols 0-2 ({15,85,28} fires bits 0+2 at lum 50; {149,186,126} none)
   must give 0x5, 0, 0x5 on the line's three output rows: per-source replication would
   give 0x5, 0x5, 0x5, and full per-output decisions (bn row 2, {215,145,180}) 0x5, 0, 0. *)
let port_selfchecks_big =
  [ ( port_prelude
      ^ "unsigned char sbuf[64000]; int kd2(int i){ unsigned int *fb; int k; int r; fb = \
         (unsigned int *)__fb_base; r = 0; DG_ScreenBuffer = sbuf; for (k = 0; k < \
         64000; k++) sbuf[k] = 0; for (k = 0; k < 256; k++) { colors[k].b = 0; \
         colors[k].g = 0; colors[k].r = 0; colors[k].a = 0; } palette_changed = 1; \
         fb[-1] = 0x12345678u; fb[768 * 32] = 0x12345678u; fb[0] = 0xAAAAAAAAu; fb[767 * \
         32 + 31] = 0xAAAAAAAAu; DG_DrawFrame(); r += (palette_changed == 0); r += \
         (fb[0] == 0) * 2; r += (fb[767 * 32] == 0) * 4; r += (fb[767 * 32 + 31] == 0) * \
         8; r += (fb[400 * 32 + 16] == 0) * 16; r += (fb[-1] == 0x12345678u) * 32; r += \
         (fb[768 * 32] == 0x12345678u) * 64; colors[0].b = 255; colors[0].g = 255; \
         colors[0].r = 255; palette_changed = 1; DG_DrawFrame(); r += (fb[0] == \
         0xFFFFFFFFu) * 128; r += (fb[767 * 32 + 31] == 0xFFFFFFFFu) * 256; return r + \
         (i - i); }"
    , "kd2"
    , [ 0, 511; 1, 511 ] )
  ; ( port_prelude
      ^ "unsigned char fpal[1024]; unsigned char fsrc[64000]; unsigned int ofb[24576]; \
         int kdf(int i){ int k; int r; for (k = 0; k < 1024; k++) fpal[k] = 0; fpal[4] = \
         255; fpal[5] = 255; fpal[6] = 255; fpal[8] = 50; fpal[9] = 50; fpal[10] = 50; \
         __dg_build_lut(fpal); for (k = 0; k < 64000; k++) fsrc[k] = 0; fsrc[0] = 1; \
         fsrc[4] = 1; fsrc[9] = 1; for (k = 320; k < 640; k++) fsrc[k] = 1; \
         __dg_dither_fs(fsrc, ofb + 767 * 32, -32); r = (ofb[767 * 32] == 0xF000F007u); \
         r += (ofb[766 * 32] == 0xF000F007u) * 2; r += (ofb[765 * 32] == 0xF000F007u) * \
         4; r += (ofb[767 * 32 + 1] == 0) * 8; r += (ofb[764 * 32] == 0xFFFFFFFFu) * 16; \
         r += (ofb[761 * 32 + 31] == 0xFFFFFFFFu) * 32; r += (ofb[760 * 32] == 0) * 64; \
         r += (ofb[0] == 0) * 128; fsrc[0] = 2; fsrc[4] = 0; fsrc[9] = 0; for (k = 320; \
         k < 640; k++) fsrc[k] = 0; __dg_dither_fs(fsrc, ofb + 767 * 32, -32); r += \
         (ofb[767 * 32] == 5) * 256; r += (ofb[766 * 32] == 0) * 512; r += (ofb[765 * \
         32] == 5) * 1024; return r + (i - i); }"
    , "kdf"
    , [ 0, 2047; 2, 2047 ] )
  ]
;;

(* the dither differential: gcc compiles the shipped dither.c, our side runs the hand
   drawer in its place, so a divergence is a drawer (or codegen) bug. Checksums cross the
   diff, never pointers. *)
let dither_src = In_channel.with_open_text (libc_path "dither.c") In_channel.input_all

let port_diff_samples =
  List.map (fun (src, name, arity) -> port_prelude ^ src, name, arity)
  @@ [ ( "unsigned char gpal[1024]; unsigned char gsrc[64000]; unsigned int gfb[24576]; \
          int dfs(int a){ int i; unsigned int s; for (i = 0; i < 256; i++) { gpal[4 * i] \
          = i; gpal[4 * i + 1] = (i * 3) & 255; gpal[4 * i + 2] = (i * 7) & 255; gpal[4 \
          * i + 3] = 0; } __dg_build_lut(gpal); for (i = 0; i < 64000; i++) gsrc[i] = (i \
          * 17 + (a & 0xFFFF)) & 255; __dg_dither_fs(gsrc, gfb + 767 * 32, -32); s = 0; \
          for (i = 0; i < 24576; i++) s = s * 31 + gfb[i]; return s; }"
       , "dfs"
       , 1
         (* the hand __dg_dither_fs, and __dg_build_lut, against gcc compiling them:
            an arg-seeded frame through every rank of every slot, the whole panel
            hashed in order *)
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
let check_sample
      ?(libc = false)
      ?(port = false)
      ?(gcc_extra = "")
      ?steps
      (src, fname, arity)
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
       let ours = u32 (Runner.run ~data ?steps body args) in
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

let contains ~sub s =
  let n = String.length sub in
  let rec at i = i + n <= String.length s && (String.sub s i n = sub || at (i + 1)) in
  at 0
;;

(* one reject: the gate must raise Unsupported rather than miscompile — and for the
   reason [want] names (any refusal would otherwise do: a sample whose gate regressed
   could still be refused downstream for something else); returns 1 on a failure *)
let check_reject (src, fname, want) : int =
  match dcc_compile ~src ~fname () with
  | exception Check.Unsupported msg when contains ~sub:want msg ->
    Printf.printf "  reject %-6s ✓ (%s)\n" fname msg;
    0
  | exception Check.Unsupported msg ->
    Printf.printf "  reject %-6s ✗ — refused for the WRONG reason: %s\n" fname msg;
    1
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
         let c, f =
           check_sample
             ~libc:true
             ~port:true
             ~gcc_extra:dither_src
             ~steps:10_000_000
             sample
         in
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
      ~port:true (* two fullscreen blits per sample: budget for them *)
      ~steps:90_000_000
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
