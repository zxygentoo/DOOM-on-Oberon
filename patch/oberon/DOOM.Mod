MODULE DOOM; (*the 2c stub — load blob + WAD into himem and run DOOM.
  Mirrors bin/doomrun.ml's loader obligations (ABI par 7/8): image at BlobBase, header
  verified (magic/version/length/checksum), bss zeroed per header, WAD chunks
  concatenated at WadBase, SHARED page zeroed + WAD length at +28 + command tail at
  +1024, then Init/Tick through the crt0 thunks.
  Two presentations, one blob:
  - DOOM.Run / DOOM.RunHW: the v1 fullscreen SEIZE — the loop never returns to
    Oberon.Loop, so the stub owns the raw PS/2 FIFO (make/break + E0 arrows that
    Input.Mod drops) and the game is fully playable.
  - DOOM.Window (seam v2, viewer presentation): an ordinary MenuViewers viewer; an
    Oberon.Task calls Tick once per loop pass, the STUB owns the Halftone rect (the
    largest 4:3 rect in the frame; SHARED +544 bit 1 tells the blob to keep only
    thresholds/LUT/frame-copy), and the desktop stays LIVE around the game.
    Keys are POINT-TO-PLAY (the par 6 v2 input slice): while the pointer is over
    the game frame, Input.SetSink (the raw-scancode tap patched into Input.Mod —
    patch/oberon/Input.Mod.patch, applied by mkdisk like the agent autoload patch) hands
    the untranslated make/break stream to the same Byte FSM the seize loop uses —
    full arrows/modifiers, identical feel; move the pointer off the game and the
    keyboard is Oberon's again (type in the Log mid-game). System.Close abandons
    the game (the next Run/Window reloads fresh).*)

  (*import order: ORB wants interface-referenced modules first — Display before
    Viewers, Viewers/Texts before Oberon, MenuViewers/TextFrames after (the proven
    Mandel.Mod order)*)
  IMPORT SYSTEM, Files, Input, Display, Viewers, Texts, Oberon, MenuViewers,
    TextFrames, Halftone;

  CONST
    (*ABI par 8 himem layout*)
    BlobBase = 100000H; BlobCap = 2C0000H;   (*blob row: 1.75 MB*)
    SharedBase = 300000H; SharedSize = 1000H;
    CmdTail = 1024; CmdTailMax = 3000;       (*offsets within SHARED*)
    WadBase = 0A00000H; WadEnd = 0E01000H;   (*4 MiB + one page*)
    Magic = 4D4F4F44H; (*"DOOM" little-endian*)
    (*keyboard MMIO (Input.Mod's addresses; bit 28 of msAdr = byte ready)*)
    msAdr = -40; kbdAdr = -36;
    (*doomkeys.h*)
    KeyLeft = 0ACH; KeyUp = 0ADH; KeyRight = 0AEH; KeyDown = 0AFH;
    KeyStrafeL = 0A0H; KeyStrafeR = 0A1H; KeyUse = 0A2H; KeyFire = 0A3H;
    KeyEsc = 27; KeyEnter = 13; KeyTab = 9; KeyBksp = 7FH;
    KeyShift = 0B6H; KeyAlt = 0B8H; (*KEY_RSHIFT, KEY_RALT*)

  TYPE
    InitProc = PROCEDURE (wad, cfg: INTEGER): INTEGER;
    TickProc = PROCEDURE (): INTEGER;
    KeyProc = PROCEDURE (ev: INTEGER);
    Frame = POINTER TO FrameDesc;
    FrameDesc = RECORD (Display.FrameDesc) END ;

  VAR
    W: Texts.Writer;
    init: InitProc; tick: TickProc; keyin: KeyProc;
    up, ext: BOOLEAN;               (*PS/2 F0/E0 prefix state*)
    tabN, tabE: ARRAY 256 OF BYTE;  (*scancode -> doomkey; 0 = ignore*)
    T: Oberon.Task;                 (*DOOM.Window: one Tick per Oberon.Loop pass*)
    V: Viewers.Viewer;              (*the window viewer; NIL = none*)
    F: Frame;
    modeOn: BOOLEAN;
    captured: BOOLEAN;              (*point-to-play: the raw tap is ours*)

  PROCEDURE Msg(s: ARRAY OF CHAR);
  BEGIN Texts.WriteString(W, s); Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf)
  END Msg;

  PROCEDURE MsgInt(s: ARRAY OF CHAR; n: INTEGER);
  BEGIN Texts.WriteString(W, s); Texts.WriteInt(W, n, 8); Texts.WriteLn(W);
    Texts.Append(Oberon.Log, W.buf)
  END MsgInt;

  (*copy a file into himem at adr, whole words (ReadInt is little-endian, matching
    the raw bytes; the padded tail rides ReadByte's zeros-at-eof). len = -1 missing,
    -2 over cap.*)
  PROCEDURE LoadFileAt(name: ARRAY OF CHAR; adr, cap: INTEGER; VAR len: INTEGER);
    VAR f: Files.File; r: Files.Rider; w, i, n: INTEGER;
  BEGIN f := Files.Old(name);
    IF f = NIL THEN len := -1
    ELSE len := Files.Length(f);
      IF len > cap THEN len := -2
      ELSE Files.Set(r, f, 0); n := (len + 3) DIV 4; i := 0;
        WHILE i < n DO Files.ReadInt(r, w); SYSTEM.PUT(adr + i*4, w); INC(i) END
      END
    END
  END LoadFileAt;

  (*ABI par 7 header checks, doomrun's verify_header transliterated*)
  PROCEDURE VerifyHeader(len: INTEGER): BOOLEAN;
    VAR ok: BOOLEAN; w, sum, i, bs, bl: INTEGER;
  BEGIN ok := FALSE;
    SYSTEM.GET(BlobBase, w);
    IF w # Magic THEN Msg("DOOM: bad magic (not a DOOM blob)")
    ELSE SYSTEM.GET(BlobBase + 4, w);
      IF w # 1 THEN MsgInt("DOOM: blob version, want 1:", w)
      ELSE SYSTEM.GET(BlobBase + 8, w);
        IF w # len THEN MsgInt("DOOM: header length <> file length:", w)
        ELSE sum := 0;
          FOR i := 16 TO len DIV 4 - 1 DO SYSTEM.GET(BlobBase + i*4, w); sum := sum + w END ;
          SYSTEM.GET(BlobBase + 32, w);
          IF w # sum THEN Msg("DOOM: checksum mismatch")
          ELSE SYSTEM.GET(BlobBase + 12, bs); SYSTEM.GET(BlobBase + 16, bl);
            SYSTEM.GET(BlobBase + 20, i); SYSTEM.GET(BlobBase + 24, w);
            SYSTEM.GET(BlobBase + 28, sum);
            IF (i = 0) OR (w = 0) OR (sum = 0) THEN Msg("DOOM: Init/Tick/KeyIn entry missing")
            ELSIF (bs < BlobBase) OR (bs + bl > BlobCap) THEN Msg("DOOM: bss range out of blob row")
            ELSE ok := TRUE
            END
          END
        END
      END
    END ;
    RETURN ok
  END VerifyHeader;

  (*the command tail (ABI par 8, SHARED +1024): the rest of the command line after
    "DOOM.Run", verbatim — ended by ~, end of text, or end of line (so a bare
    DOOM.Run in a Tool doesn't swallow the lines below it)*)
  PROCEDURE CopyArgs;
    VAR r: Texts.Reader; ch: CHAR; a: INTEGER; b: BYTE;
  BEGIN a := SharedBase + CmdTail;
    Texts.OpenReader(r, Oberon.Par.text, Oberon.Par.pos); Texts.Read(r, ch);
    WHILE ~r.eot & (ch # "~") & (ch >= " ") & (a < SharedBase + CmdTail + CmdTailMax) DO
      b := ORD(ch); SYSTEM.PUT(a, b); INC(a); Texts.Read(r, ch)
    END
  END CopyArgs;

  (*---- raw PS/2 keyboard (par 6 path 2) ----*)

  PROCEDURE DrainKbd;
    VAR b: BYTE;
  BEGIN WHILE SYSTEM.BIT(msAdr, 28) DO SYSTEM.GET(kbdAdr, b) END ;
    up := FALSE; ext := FALSE
  END DrainKbd;

  (*one byte of the scancode stream: F0 = break prefix, E0 = extended prefix,
    else a key. The emulator (and a real keyboard) wraps arrows in fake-shift
    E0 12 / E0 F0 12 — tabE[12H] = 0 swallows it. Event = pressed | doomkey<<8.
    Shared by the seize loop's FIFO drain (PollKeys) and DOOM.Window's raw tap
    (Input.SetSink feeds it from inside Oberon.Loop's own polling).*)
  PROCEDURE Byte(b: BYTE);
    VAR dk: INTEGER;
  BEGIN
    IF b = 0F0H THEN up := TRUE
    ELSIF b = 0E0H THEN ext := TRUE
    ELSE
      IF ext THEN dk := tabE[b] ELSE dk := tabN[b] END ;
      IF dk # 0 THEN
        IF up THEN keyin(dk * 100H) ELSE keyin(dk * 100H + 1) END
      END ;
      up := FALSE; ext := FALSE
    END
  END Byte;

  PROCEDURE PollKeys;
    VAR b: BYTE;
  BEGIN
    WHILE SYSTEM.BIT(msAdr, 28) DO SYSTEM.GET(kbdAdr, b); Byte(b) END
  END PollKeys;

  (*repaint the desktop DOOM scribbled over: viewer state lives in the heap, only
    pixels were lost — one restore broadcast redraws every frame and filler*)
  PROCEDURE Restore;
    VAR M: Viewers.ViewerMsg;
  BEGIN M.id := Viewers.restore; Viewers.Broadcast(M)
  END Restore;

  (*load blob + WAD, verify, stub obligations (bss zero, SHARED zero + WAD length +
    presentation bits at +544 + command tail), plant the entries. TRUE = ready for
    init(). hwbits: 0 = software dither, 1 = hardware scanout (blob owns
    mode+geometry), 3 = viewer presentation (bit 1: the STUB owns mode+geometry —
    the blob keeps thresholds/LUT/frame-copy). Bits only meaningful on a bitstream
    that carries Halftone — on the stock bitstream hw modes play blind.*)
  PROCEDURE Load(hwbits: INTEGER): BOOLEAN;
    VAR ok: BOOLEAN; blobLen, wadLen, len, i, a, w: INTEGER;
      name: ARRAY 16 OF CHAR;
  BEGIN ok := FALSE;
    Msg("DOOM: loading doom.blob");
    LoadFileAt("doom.blob", BlobBase, BlobCap - BlobBase, blobLen);
    IF blobLen = -1 THEN Msg("DOOM: doom.blob not found")
    ELSIF blobLen = -2 THEN Msg("DOOM: doom.blob exceeds the blob row")
    ELSIF blobLen < 64 THEN Msg("DOOM: doom.blob too short")
    ELSIF VerifyHeader(blobLen) THEN
      (*WAD chunks doom1.wad.0, .1, ... concatenated at WadBase (par 3)*)
      wadLen := 0; i := 0; len := 0; name := "doom1.wad.0";
      WHILE (i <= 9) & (len >= 0) DO
        name[10] := CHR(ORD("0") + i);
        LoadFileAt(name, WadBase + wadLen, WadEnd - WadBase - wadLen, len);
        IF len >= 0 THEN wadLen := wadLen + len; INC(i) END
      END ;
      IF len = -2 THEN Msg("DOOM: WAD exceeds the par 8 window")
      ELSIF wadLen = 0 THEN Msg("DOOM: doom1.wad.0 not found")
      ELSE
        MsgInt("DOOM: WAD bytes:", wadLen);
        (*stub obligations before Init: bss zero, SHARED zero, WAD length, args*)
        SYSTEM.GET(BlobBase + 12, a); SYSTEM.GET(BlobBase + 16, len);
        FOR w := a TO a + len - 4 BY 4 DO SYSTEM.PUT(w, 0) END ;
        FOR w := SharedBase TO SharedBase + SharedSize - 4 BY 4 DO SYSTEM.PUT(w, 0) END ;
        SYSTEM.PUT(SharedBase + 28, wadLen);
        IF hwbits # 0 THEN SYSTEM.PUT(SharedBase + 544, hwbits) END ;
        CopyArgs;
        SYSTEM.GET(BlobBase + 20, w); SYSTEM.PUT(SYSTEM.ADR(init), BlobBase + w);
        SYSTEM.GET(BlobBase + 24, w); SYSTEM.PUT(SYSTEM.ADR(tick), BlobBase + w);
        SYSTEM.GET(BlobBase + 28, w); SYSTEM.PUT(SYSTEM.ADR(keyin), BlobBase + w);
        ok := TRUE
      END
    END ;
    RETURN ok
  END Load;

  PROCEDURE Run0(hw: BOOLEAN);
    VAR r, st, bits: INTEGER;
  BEGIN
    IF V # NIL THEN Msg("DOOM: close the DOOM window first")
    ELSE
      IF hw THEN bits := 1 ELSE bits := 0 END ;
      IF Load(bits) THEN
        Msg("DOOM: Init (D_DoomMain takes a while)");
        r := init(WadBase, SharedBase);
        IF r # 0 THEN Restore; MsgInt("DOOM: Init failed:", r)
        ELSE (*the seize loop: keys between ticks, until quit or I_Error*)
          DrainKbd; st := 0; r := 0;
          REPEAT PollKeys; r := tick(); SYSTEM.GET(SharedBase + 12, st)
          UNTIL (r # 0) OR (st # 0);
          Restore;
          IF st > 1 THEN st := 0 END ; (*1 = clean quit; negatives = I_Error*)
          MsgInt("DOOM: exit status", st)
        END
      END
    END
  END Run0;

  PROCEDURE Run*;
  BEGIN Run0(FALSE)
  END Run;

  PROCEDURE RunHW*;
  BEGIN Run0(TRUE)
  END RunHW;

  (*---- DOOM.Window: the viewer presentation (seam v2) ----*)

  PROCEDURE Paint(x, y, w, h: INTEGER);  (*the frame ground around the rect*)
  BEGIN Oberon.RemoveMarks(x, y, w, h);
    Display.ReplConst(Display.black, x, y, w, h, Display.replace)
  END Paint;

  PROCEDURE Shape(fx, fy, fw, fh: INTEGER): BOOLEAN;
    (*the largest 4:3 rect in the frame: w a multiple of 32 and >= 320 (the DDA
      upscales only), h = w*3/4 = (w DIV 32)*24 (even), centred; horizontal scale
      w/320 reduced by the gcd (>= 32, since 32 divides both). w = 576 (user track)
      gives 9/5; w = 1024 would give the fullscreen 16/5 through the same math.*)
    VAR x0, x1, w, h, yt, a, b, g: INTEGER; ok: BOOLEAN;
  BEGIN
    x0 := (fx + 31) DIV 32 * 32;
    x1 := (fx + fw) DIV 32 * 32;
    w := x1 - x0;
    h := (w DIV 32) * 24;
    IF h > fh THEN  (*height-bound: shrink w to keep the aspect*)
      w := fh * 4 DIV 3 DIV 32 * 32; h := (w DIV 32) * 24
    END ;
    ok := w >= 320;
    IF ok THEN
      x0 := x0 + (x1 - x0 - w) DIV 64 * 32;
      yt := Display.Height - fy - fh + (fh - h) DIV 2;
      a := w; b := 320;
      WHILE b # 0 DO g := a MOD b; a := b; b := g END ;
      ok := Halftone.Open(x0, yt, w, h, w DIV a, 320 DIV a, 0);
      IF ok THEN Halftone.LinearRows(200, 320, h) END
    END ;
    RETURN ok
  END Shape;

  (*point-to-play: the raw tap (Input.Mod.patch) is ours exactly while the pointer
    is over the game frame — park the mouse on DOOM to play with the seize loop's
    full make/break fidelity; move it off and the keyboard is Oberon's again. The
    sink feeds Byte from inside Oberon.Loop's own input polling, so events land in
    the blob's key ring between ticks, exactly like the seize loop's PollKeys.*)
  PROCEDURE Capture;
    VAR keys: SET; mx, my: INTEGER; inside: BOOLEAN;
  BEGIN
    Input.Mouse(keys, mx, my);
    inside := (mx >= F.X) & (mx < F.X + F.W) & (my >= F.Y) & (my < F.Y + F.H);
    IF inside # captured THEN
      captured := inside;
      IF inside THEN up := FALSE; ext := FALSE; Input.SetSink(Byte)
      ELSE Input.SetSink(NIL)
      END
    END
  END Capture;

  PROCEDURE Release;
  BEGIN
    IF captured THEN Input.SetSink(NIL); captured := FALSE END
  END Release;

  PROCEDURE Tick0;  (*the task: lifecycle + one blob Tick per Oberon.Loop pass*)
    VAR r, st: INTEGER;
  BEGIN
    IF (V = NIL) OR (V.state = 0) THEN  (*System.Close: abandon the game*)
      Release;
      IF modeOn THEN Halftone.Off; modeOn := FALSE END ;
      V := NIL; F := NIL; Oberon.Remove(T); Msg("DOOM: window closed")
    ELSIF V.state < 0 THEN  (*suspended (covered track): release the panel*)
      Release;
      IF modeOn THEN Halftone.Off; modeOn := FALSE END
    ELSE  (*displayed*)
      IF ~modeOn & (F # NIL) THEN  (*fresh, resized or redisplayed: (re)claim.
        The blob uploaded its thresholds + LUT during Init's first frame*)
        IF Shape(F.X, F.Y, F.W, F.H) THEN Halftone.On; modeOn := TRUE END
      END ;
      IF modeOn THEN
        Capture;  (*point-to-play: keys are ours while the pointer is over the game*)
        r := tick(); SYSTEM.GET(SharedBase + 12, st);
        IF (r # 0) OR (st # 0) THEN  (*quit or I_Error (timedemo ends here)*)
          Release;
          Halftone.Off; modeOn := FALSE;
          Oberon.Remove(T);
          Viewers.Close(V); V := NIL; F := NIL;
          IF st > 1 THEN st := 0 END ;
          MsgInt("DOOM: exit status", st)
        END
      END
    END
  END Tick0;

  PROCEDURE Handle(G: Display.Frame; VAR M: Display.FrameMsg);
  BEGIN
    CASE G OF Frame:
      CASE M OF
        Oberon.InputMsg:
          IF M(Oberon.InputMsg).id = Oberon.track THEN
            Oberon.DrawMouseArrow(M(Oberon.InputMsg).X, M(Oberon.InputMsg).Y)
          END
      | MenuViewers.ModifyMsg:
          (*open / neighbour resize / suspend (H = 0) — drop the mode, let the next
            displayed tick re-Shape against the updated frame*)
          IF (M.Y # G.Y) OR (M.H # G.H) THEN
            IF modeOn THEN Halftone.Off; modeOn := FALSE END ;
            IF M.H > 0 THEN Paint(G.X, M.Y, G.W, M.H) END
          END
      END
    END
  END Handle;

  PROCEDURE Window*;
    VAR r, X, Y: INTEGER;
  BEGIN
    IF V # NIL THEN Msg("DOOM: window already open")
    ELSIF Load(3) THEN
      Msg("DOOM: Init (D_DoomMain takes a while)");
      r := init(WadBase, SharedBase);
      IF r # 0 THEN MsgInt("DOOM: Init failed:", r)
      ELSE
        NEW(F); F.handle := Handle; modeOn := FALSE; captured := FALSE;
        Oberon.AllocateUserViewer(Oberon.Par.vwr.X, X, Y);
        V := MenuViewers.New(
          TextFrames.NewMenu("DOOM", "System.Close"),
          F, TextFrames.menuH, X, Y);
        Oberon.Install(T);
        Msg("DOOM: windowed — point the mouse at the game to play; System.Close to stop")
      END
    END
  END Window;

  PROCEDURE InitTables;
    VAR i: INTEGER;

    PROCEDURE N(sc, dk: INTEGER);
    BEGIN tabN[sc] := dk
    END N;

    PROCEDURE E(sc, dk: INTEGER);
    BEGIN tabE[sc] := dk
    END E;

  BEGIN
    FOR i := 0 TO 255 DO tabN[i] := 0; tabE[i] := 0 END ;
    (*letters -> lowercase ASCII: menus (y/n), save names, cheats — iddqd needs its d*)
    N(1CH, ORD("a")); N(32H, ORD("b")); N(21H, ORD("c")); N(23H, ORD("d"));
    N(24H, ORD("e")); N(2BH, ORD("f")); N(34H, ORD("g")); N(33H, ORD("h"));
    N(43H, ORD("i")); N(3BH, ORD("j")); N(42H, ORD("k")); N(4BH, ORD("l"));
    N(3AH, ORD("m")); N(31H, ORD("n")); N(44H, ORD("o")); N(4DH, ORD("p"));
    N(15H, ORD("q")); N(2DH, ORD("r")); N(1BH, ORD("s")); N(2CH, ORD("t"));
    N(3CH, ORD("u")); N(2AH, ORD("v")); N(1DH, ORD("w")); N(22H, ORD("x"));
    N(35H, ORD("y")); N(1AH, ORD("z"));
    (*digits: episode/level/weapon select, idclev/idmus arguments*)
    N(16H, ORD("1")); N(1EH, ORD("2")); N(26H, ORD("3")); N(25H, ORD("4"));
    N(2EH, ORD("5")); N(36H, ORD("6")); N(3DH, ORD("7")); N(3EH, ORD("8"));
    N(46H, ORD("9")); N(45H, ORD("0"));
    (*movement + action (m_controls.c defaults)*)
    N(14H, KeyFire);            (*Ctrl*)
    N(29H, KeyUse);             (*Space*)
    N(12H, KeyShift); N(59H, KeyShift);  (*run*)
    N(11H, KeyAlt);             (*LAlt: hold to strafe with arrows*)
    N(41H, KeyStrafeL); N(49H, KeyStrafeR);  (*comma/period*)
    N(75H, KeyUp); N(72H, KeyDown); N(6BH, KeyLeft); N(74H, KeyRight); (*keypad 8 2 4 6*)
    (*chrome*)
    N(5AH, KeyEnter); N(76H, KeyEsc); N(0DH, KeyTab); N(66H, KeyBksp);
    N(4EH, ORD("-")); N(55H, ORD("=")); (*screen size*)
    N(05H, 0BBH); N(06H, 0BCH); N(04H, 0BDH); N(0CH, 0BEH);  (*F1-F4*)
    N(03H, 0BFH); N(0BH, 0C0H); N(83H, 0C1H); N(0AH, 0C2H);  (*F5-F8*)
    N(01H, 0C3H); N(09H, 0C4H); N(78H, 0D7H); N(07H, 0D8H);  (*F9-F12; F11 = gamma*)
    (*E0-extended: the real arrows, right Ctrl/Alt, keypad enter.
      tabE[12H] stays 0: the fake-shift wrapper around arrows is swallowed.*)
    E(75H, KeyUp); E(72H, KeyDown); E(6BH, KeyLeft); E(74H, KeyRight);
    E(14H, KeyFire); E(11H, KeyAlt); E(5AH, KeyEnter)
  END InitTables;

BEGIN Texts.OpenWriter(W); up := FALSE; ext := FALSE; InitTables;
  T := Oberon.NewTask(Tick0, 0)
END DOOM.
