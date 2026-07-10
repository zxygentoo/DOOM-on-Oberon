MODULE Mandel; (*feat/indexbuf demo — the indexed-colour display mode's SECOND client,
  sharing zero code and zero content with DOOM: an ordinary Oberon command that
  computes a Mandelbrot set (REAL arithmetic — the machine's own FPU), uploads its
  OWN dither rendition (a computed Bayer 8x8 matrix, deliberately not DOOM's blue
  noise), paints palette bytes into the pixel window, and flips the mode bit. The
  desktop is untouched underneath: clearing the bit restores it instantly.
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
    W = 320; H = 200; MaxIter = 48;

  VAR Wr: Texts.Writer;
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

  PROCEDURE Draw*;
    VAR px, py, it, v, a: INTEGER; c: CHAR; b: BYTE;
      cr, ci, zr, zi, t: REAL;
  BEGIN
    Msg("Mandel: computing");
    Upload; Lut;
    a := PixBase;
    FOR py := 0 TO H - 1 DO
      ci := (FLT(py) - 100.0) * 0.012;
      FOR px := 0 TO W - 1 DO
        cr := (FLT(px) - 224.0) * 0.0109375;
        zr := 0.0; zi := 0.0; it := 0;
        WHILE (it < MaxIter) & (zr * zr + zi * zi < 4.0) DO
          t := zr * zr - zi * zi + cr;
          zi := 2.0 * zr * zi + ci;
          zr := t;
          INC(it)
        END ;
        (*escape-time glow: near the set bright, far outside dark, interior black*)
        IF it = MaxIter THEN v := 0 ELSE v := (it * 255) DIV MaxIter END ;
        c := CHR(v); SYSTEM.PUT(a, c); INC(a)
      END
    END ;
    SYSTEM.PUT(CtlAdr, 1);
    Msg("Mandel: shown — press any key to return");
    (*drain stale scancodes, wait for a key, swallow the make (and, briefly, the
      break) so Oberon does not replay our exit key; a stray F0-pair later is
      harmless to Input.Mod's FSM*)
    WHILE SYSTEM.BIT(msAdr, 28) DO SYSTEM.GET(kbdAdr, b) END ;
    REPEAT UNTIL SYSTEM.BIT(msAdr, 28);
    FOR it := 0 TO 400000 DO
      WHILE SYSTEM.BIT(msAdr, 28) DO SYSTEM.GET(kbdAdr, b) END
    END ;
    SYSTEM.PUT(CtlAdr, 0);  (*the desktop was under us all along*)
    Msg("Mandel: done")
  END Draw;

BEGIN Texts.OpenWriter(Wr); BuildBayer;
  xw[0] := 3; xw[1] := 3; xw[2] := 3; xw[3] := 3; xw[4] := 4;
  xw[5] := 3; xw[6] := 3; xw[7] := 3; xw[8] := 3; xw[9] := 4;
  xoff[0] := 0; xoff[1] := 3; xoff[2] := 6; xoff[3] := 9; xoff[4] := 12;
  xoff[5] := 16; xoff[6] := 19; xoff[7] := 22; xoff[8] := 25; xoff[9] := 28
END Mandel.
