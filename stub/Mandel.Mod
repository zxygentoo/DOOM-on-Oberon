MODULE Mandel; (*feat/indexbuf demo — the indexed-colour display mode's SECOND client,
  sharing zero code and zero content with DOOM: an ordinary Oberon command that
  animates a Mandelbrot zoom (REAL arithmetic — the machine's own FPU), uploads its
  OWN dither rendition (a computed Bayer 8x8 matrix, deliberately not DOOM's blue
  noise), paints palette bytes into the pixel window, and flips the mode bit. The
  desktop is untouched underneath: clearing the bit restores it instantly.
  The animation is the classic infinite zoom: a boundary target (seahorse valley)
  pinned at screen centre, the scale shrinking 15% per frame, painted progressively
  into the live pixel window. REAL is single precision — near |CX| ~ 0.74 one ulp
  is ~6.0E-8 — so when the pixel step falls under SxMin (~8 ulp) adjacent columns
  would quantize to the same cr; the scale resets there and the zoom loops
  (~62 frames, ~22000x): the "infinite" is a loop, sized by the mantissa.
  Contract (draft seam indexbuf-seam.md): pixel window 310000H (320x200 bytes,
  row 0 = top), luminance LUT +64000, control word +64256 (bit 0 = mode),
  threshold quads at 30E000H — 2048 words, a = row*32 + phase*16 + slot, the
  slot's 3-or-4 thresholds one byte each (slots cover 3/3/3/3/4 output bits at
  offsets 0/3/6/9/12 within each half-word phase; K=3 slots pad with 255).
  Mode-on REQUIRES a prior threshold upload: the RAM powers up zero.*)

  IMPORT SYSTEM, Texts, Oberon;

  CONST
    PixBase = 310000H; LutBase = 31FA00H; CtlAdr = 31FB00H; ThrBase = 30E000H;
    msAdr = -40; kbdAdr = -36;  (*keyboard MMIO, bit 28 of msAdr = byte ready*)
    timAdr = -64;               (*millisecond counter*)
    W = 320; H = 200;
    CX = -0.7436439; CY = 0.1318259;  (*zoom target: seahorse valley*)
    Sx0 = 0.0109375; Sy0 = 0.012;     (*frame-1 pixel steps — the full-set view*)
    Zoom = 0.85;                      (*scale factor per frame*)
    SxMin = 5.0E-7;                   (*precision floor: reset and loop*)
    Iter0 = 48; IterMax = 128;        (*escape limit grows with depth, +2/frame*)

  VAR Wr: Texts.Writer;
    quit: BOOLEAN;                (*set by Frame on any keyboard byte*)
    bay: ARRAY 8, 8 OF INTEGER;   (*Bayer 8x8, values 0..63*)
    xw, xoff: ARRAY 10 OF INTEGER;

  PROCEDURE Msg(s: ARRAY OF CHAR);
  BEGIN Texts.WriteString(Wr, s); Texts.WriteLn(Wr); Texts.Append(Oberon.Log, Wr.buf)
  END Msg;

  (*the classic recursive doubling: M(2n)[q] = 4*M(n) + (0|2|3|1) by quadrant*)
  PROCEDURE BuildBayer;
    VAR n, i, j, v: INTEGER;
  BEGIN bay[0, 0] := 0; n := 1;
    WHILE n < 8 DO
      FOR i := 0 TO n - 1 DO
        FOR j := 0 TO n - 1 DO
          v := bay[i, j];
          bay[i, j + n] := 4 * v + 2;
          bay[i + n, j] := 4 * v + 3;
          bay[i + n, j + n] := 4 * v + 1;
          bay[i, j] := 4 * v
        END
      END ;
      n := 2 * n
    END
  END BuildBayer;

  PROCEDURE Thr(x, y: INTEGER): INTEGER;  (*64x64 map = Bayer tiled, 0..63 -> 2..254*)
  BEGIN RETURN bay[y MOD 8, x MOD 8] * 4 + 2
  END Thr;

  PROCEDURE Upload;  (*derive + upload the 2048 slot quads from OUR threshold map*)
    VAR r, p, j, k, t, q: INTEGER;
  BEGIN
    FOR r := 0 TO 63 DO
      FOR p := 0 TO 1 DO
        FOR j := 0 TO 9 DO
          q := 0;
          FOR k := 3 TO 0 BY -1 DO
            IF k < xw[j] THEN t := Thr(32 * p + xoff[j] + k, r) ELSE t := 255 END ;
            q := LSL(q, 8) + t
          END ;
          SYSTEM.PUT(ThrBase + 4 * (r * 32 + p * 16 + j), q)
        END
      END
    END
  END Upload;

  PROCEDURE Lut;  (*identity ramp: palette byte = luminance — iteration count IS brightness*)
    VAR i: INTEGER; c: CHAR;
  BEGIN
    FOR i := 0 TO 255 DO c := CHR(i); SYSTEM.PUT(LutBase + i, c) END
  END Lut;

  PROCEDURE Frame(sx, sy: REAL; lim: INTEGER);
    VAR px, py, it, v, a: INTEGER; c: CHAR;
      cr, ci, zr, zi, zr2, zi2, t, q: REAL;
  BEGIN a := PixBase; py := 0;
    WHILE (py < H) & ~quit DO
      ci := CY + FLT(100 - py) * sy;  (*row 0 = top of image = +i up*)
      FOR px := 0 TO W - 1 DO
        cr := CX + FLT(px - 160) * sx;
        (*exact interior tests — main cardioid, then period-2 bulb — skip the
          pixels that would burn the full lim: at this target roughly half the
          screen is set-interior at every depth*)
        t := cr - 0.25; q := t * t + ci * ci;
        IF q * (q + t) <= 0.25 * (ci * ci) THEN v := 0
        ELSIF (cr + 1.0) * (cr + 1.0) + ci * ci <= 0.0625 THEN v := 0
        ELSE
          zr := 0.0; zi := 0.0; zr2 := 0.0; zi2 := 0.0; it := 0;
          WHILE (it < lim) & (zr2 + zi2 < 4.0) DO
            zi := 2.0 * zr * zi + ci;
            zr := zr2 - zi2 + cr;
            zr2 := zr * zr; zi2 := zi * zi;  (*3 multiplies/iteration, not 5*)
            INC(it)
          END ;
          (*escape-time glow: near the set bright, far outside dark, interior black*)
          IF it = lim THEN v := 0 ELSE v := (it * 255) DIV lim END
        END ;
        c := CHR(v); SYSTEM.PUT(a, c); INC(a)
      END ;
      IF SYSTEM.BIT(msAdr, 28) THEN quit := TRUE END ;  (*any key: exit, one row's latency*)
      INC(py)
    END
  END Frame;

  PROCEDURE Draw*;
    VAR lim, t0, t: INTEGER; b: BYTE; sx, sy: REAL;
  BEGIN
    Msg("Mandel: zooming — press any key to return");
    Upload; Lut;
    (*drain stale scancodes so a buffered key does not exit frame 1*)
    WHILE SYSTEM.BIT(msAdr, 28) DO SYSTEM.GET(kbdAdr, b) END ;
    quit := FALSE;
    sx := Sx0; sy := Sy0; lim := Iter0;
    Frame(sx, sy, lim);
    SYSTEM.PUT(CtlAdr, 1);  (*first frame ready — scanout live, later frames paint in place*)
    WHILE ~quit DO
      sx := Zoom * sx; sy := Zoom * sy;
      IF sx < SxMin THEN sx := Sx0; sy := Sy0; lim := Iter0  (*the loop in "infinite"*)
      ELSIF lim < IterMax THEN lim := lim + 2  (*boundary escape times grow with depth*)
      END ;
      Frame(sx, sy, lim)
    END ;
    (*swallow the exit key's make (and, briefly, the break) so Oberon does not
      replay it: drain for 200 ms on the real clock — a cycle-count spin would
      trip the emulator's idle detection (empty status polls end the timeslice)
      and crawl; a stray F0-pair later is harmless to Input.Mod's FSM*)
    SYSTEM.GET(timAdr, t0);
    REPEAT
      WHILE SYSTEM.BIT(msAdr, 28) DO SYSTEM.GET(kbdAdr, b) END ;
      SYSTEM.GET(timAdr, t)
    UNTIL t - t0 > 200;
    SYSTEM.PUT(CtlAdr, 0);  (*the desktop was under us all along*)
    Msg("Mandel: done")
  END Draw;

BEGIN Texts.OpenWriter(Wr); BuildBayer;
  xw[0] := 3; xw[1] := 3; xw[2] := 3; xw[3] := 3; xw[4] := 4;
  xw[5] := 3; xw[6] := 3; xw[7] := 3; xw[8] := 3; xw[9] := 4;
  xoff[0] := 0; xoff[1] := 3; xoff[2] := 6; xoff[3] := 9; xoff[4] := 12;
  xoff[5] := 16; xoff[6] := 19; xoff[7] := 22; xoff[8] := 25; xoff[9] := 28
END Mandel.
