MODULE Mandel; (*feat/halftone v2 demo — the display mode's first VIEWER CITIZEN (and
  Halftone.Mod's first client; zero code and zero content shared with DOOM).
  Mandel.Open opens an ordinary MenuViewers viewer (the Stars.Mod pattern) whose main
  frame hosts a Halftone rect: the largest word-aligned 2x2-pixel rect centred in the
  frame, margins painted black. An Oberon.Task renders a few Mandelbrot rows per
  Oberon.Loop pass into the pixel window — the zoom animates COOPERATIVELY: mouse,
  clock and every other viewer stay live while it runs, and the desktop repaints
  normally around it.
  Lifecycle is the viewer protocol, not key-grabbing: MenuViewers.ModifyMsg (open,
  resize by neighbours, suspend-with-H=0) drops the mode and reshapes the rect on the
  next tick; the task polls V.state so a plain System.Close from the menu works — the
  first displayed tick after any change re-claims the rect (Halftone.Open latches at
  the next vblank entry), suspended (state < 0) releases the panel, closed (state = 0)
  releases it and removes the task.
  The zoom itself: seahorse valley pinned at rect centre, scale x0.85 per frame,
  reset at the single-precision floor (~8 ulp pixel steps — the "infinite" is a loop
  sized by the mantissa), escape limit growing 48 +2/frame capped 128, exact
  cardioid + period-2-bulb interior tests. Iteration count IS brightness (identity
  tone ramp); the rendition is Halftone's computed Bayer 8x8.*)

  IMPORT SYSTEM, Display, Viewers, Texts, Oberon, MenuViewers, TextFrames, Halftone;

  CONST
    RowsPerTick = 6;                  (*render chunk per Oberon.Loop pass*)
    CX = -0.7436439; CY = 0.1318259;  (*zoom target: seahorse valley*)
    Sx0 = 0.0109375; Sy0 = 0.012;     (*frame-1 pixel steps — the full-set view*)
    Zoom = 0.85;                      (*scale factor per frame*)
    SxMin = 5.0E-7;                   (*precision floor: reset and loop*)
    Iter0 = 48; IterMax = 128;        (*escape limit grows with depth, +2/frame*)

  TYPE Frame = POINTER TO FrameDesc;
    FrameDesc = RECORD (Display.FrameDesc) END ;

  VAR T: Oberon.Task;
    Wr: Texts.Writer;
    V: Viewers.Viewer;            (*the open viewer; NIL = none (single owner)*)
    F: Frame;
    wsrc, hsrc: INTEGER;          (*visible source dims = half the claimed rect*)
    row, lim: INTEGER;            (*render cursor within the current zoom frame*)
    sx, sy: REAL;                 (*current zoom pixel steps*)
    modeOn: BOOLEAN;

  PROCEDURE Msg(s: ARRAY OF CHAR);
  BEGIN Texts.WriteString(Wr, s); Texts.WriteLn(Wr); Texts.Append(Oberon.Log, Wr.buf)
  END Msg;

  PROCEDURE RenderRow(py: INTEGER);
    (*one source row of the current zoom frame -> pixel-window row py (stride 320)*)
    VAR px, it, v, a: INTEGER; c: CHAR;
      cr, ci, zr, zi, zr2, zi2, t, q: REAL;
  BEGIN a := Halftone.base + py * 320;
    ci := CY + FLT(hsrc DIV 2 - py) * sy;  (*row 0 = top of image = +i up*)
    FOR px := 0 TO wsrc - 1 DO
      cr := CX + FLT(px - wsrc DIV 2) * sx;
      (*exact interior tests — main cardioid, then period-2 bulb — skip the pixels
        that would burn the full lim: roughly half the view is set-interior here*)
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
        IF it = lim THEN v := 0 ELSE v := (it * 255) DIV lim END
      END ;
      c := CHR(v); SYSTEM.PUT(a, c); INC(a)
    END
  END RenderRow;

  PROCEDURE Advance;  (*one zoom step, after each completed frame*)
  BEGIN sx := Zoom * sx; sy := Zoom * sy;
    IF sx < SxMin THEN sx := Sx0; sy := Sy0; lim := Iter0  (*the loop in "infinite"*)
    ELSIF lim < IterMax THEN lim := lim + 2
    END
  END Advance;

  PROCEDURE Shape(fx, fy, fw, fh: INTEGER): BOOLEAN;
    (*claim the largest 2x rect (cap 640x400) centred in the frame: x and w must be
      multiples of 32 (the claim mux selects whole fb words), h even for the 2x rows.
      FALSE = frame too small (or Open rejected); nothing claimed.*)
    VAR x0, x1, w, h, yt: INTEGER; ok: BOOLEAN;
  BEGIN
    x0 := (fx + 31) DIV 32 * 32;
    x1 := (fx + fw) DIV 32 * 32;
    w := x1 - x0;
    IF w > 640 THEN x0 := x0 + (w - 640) DIV 64 * 32; w := 640 END ;
    h := fh; IF h > 400 THEN h := 400 END ;
    h := h - h MOD 2;
    ok := (w >= 32) & (h >= 16);
    IF ok THEN
      yt := Display.Height - fy - fh + (fh - h) DIV 2;  (*panel coords, top-down*)
      ok := Halftone.Open(x0, yt, w, h, 2, 1, 0);
      IF ok THEN
        wsrc := w DIV 2; hsrc := h DIV 2;
        Halftone.LinearRows(hsrc, 320, h);
        row := 0
      END
    END ;
    RETURN ok
  END Shape;

  PROCEDURE Paint(x, y, w, h: INTEGER);  (*the frame ground: black, the Stars idiom*)
  BEGIN Oberon.RemoveMarks(x, y, w, h);
    Display.ReplConst(Display.black, x, y, w, h, Display.replace)
  END Paint;

  PROCEDURE Tick;  (*the Oberon.Task handler: lifecycle + a render chunk per pass*)
    VAR k: INTEGER;
  BEGIN
    IF (V = NIL) OR (V.state = 0) THEN  (*System.Close: release panel + task*)
      IF modeOn THEN Halftone.Off; modeOn := FALSE END ;
      V := NIL; F := NIL; Oberon.Remove(T); Msg("Mandel: closed")
    ELSIF V.state < 0 THEN  (*suspended (covered track): release the panel*)
      IF modeOn THEN Halftone.Off; modeOn := FALSE END
    ELSE  (*displayed*)
      IF ~modeOn & (F # NIL) THEN  (*fresh, resized or redisplayed: (re)claim*)
        IF Shape(F.X, F.Y, F.W, F.H) THEN
          (*tables too, every claim: the RAMs power up ZERO (an all-black rect — the
            board taught this: the emulator legs cannot see scanout), and a DOOM run
            in between would leave ITS rendition*)
          Halftone.Bayer8; Halftone.ToneIdentity;
          Halftone.On; modeOn := TRUE
        END
      END ;
      IF modeOn THEN k := 0;
        WHILE k < RowsPerTick DO
          RenderRow(row); INC(row);
          IF row = hsrc THEN row := 0; Advance END ;
          INC(k)
        END
      END
    END
  END Tick;

  PROCEDURE Handle(G: Display.Frame; VAR M: Display.FrameMsg);
  BEGIN
    CASE G OF Frame:
      CASE M OF
        Oberon.InputMsg:
          IF M(Oberon.InputMsg).id = Oberon.track THEN
            Oberon.DrawMouseArrow(M(Oberon.InputMsg).X, M(Oberon.InputMsg).Y)
          END
      | MenuViewers.ModifyMsg:
          (*open (extend from H=0), neighbour resize, suspend (reduce to H=0) — one
            protocol: drop the mode now, let the next displayed tick re-Shape against
            the updated frame (Adjust writes G.Y/G.H right after this returns)*)
          IF (M.Y # G.Y) OR (M.H # G.H) THEN
            IF modeOn THEN Halftone.Off; modeOn := FALSE END ;
            IF M.H > 0 THEN Paint(G.X, M.Y, G.W, M.H) END
          END
      END
    END
  END Handle;

  PROCEDURE Open*;
    VAR X, Y: INTEGER;
  BEGIN
    IF V # NIL THEN Msg("Mandel: already open (the panel rect is single-owner)")
    ELSE
      NEW(F); F.handle := Handle;
      sx := Sx0; sy := Sy0; lim := Iter0; row := 0; modeOn := FALSE;
      Oberon.AllocateUserViewer(Oberon.Par.vwr.X, X, Y);
      V := MenuViewers.New(
        TextFrames.NewMenu("Mandel", "System.Close"),
        F, TextFrames.menuH, X, Y);
      Oberon.Install(T);
      Msg("Mandel: zooming — System.Close to stop")
    END
  END Open;

BEGIN Texts.OpenWriter(Wr); T := Oberon.NewTask(Tick, 0)
END Mandel.
