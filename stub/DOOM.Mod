MODULE DOOM; (*the 2c stub — load blob + WAD into himem, seize the machine, run DOOM.
  Mirrors bin/doomrun.ml's loader obligations (ABI par 7/8): image at BlobBase, header
  verified (magic/version/length/checksum), bss zeroed per header, WAD chunks
  concatenated at WadBase, SHARED page zeroed + WAD length at +28 + command tail at
  +1024, then Init/Tick through the crt0 thunks. Keyboard: raw PS/2 scancodes off the
  MMIO FIFO — Oberon.Loop is parked while we run, so Input.Mod never sees them; the
  raw stream carries make/break and the E0-extended arrows that Input.Mod drops.*)

  (*import order: ORB wants interface-referenced modules first — Oberon's interface
    names Viewers and Texts, so both precede it*)
  IMPORT SYSTEM, Files, Viewers, Texts, Oberon;

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

  VAR
    W: Texts.Writer;
    init: InitProc; tick: TickProc; keyin: KeyProc;
    up, ext: BOOLEAN;               (*PS/2 F0/E0 prefix state*)
    tabN, tabE: ARRAY 256 OF BYTE;  (*scancode -> doomkey; 0 = ignore*)

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
    E0 12 / E0 F0 12 — tabE[12H] = 0 swallows it. Event = pressed | doomkey<<8.*)
  PROCEDURE PollKeys;
    VAR b: BYTE; dk: INTEGER;
  BEGIN
    WHILE SYSTEM.BIT(msAdr, 28) DO
      SYSTEM.GET(kbdAdr, b);
      IF b = 0F0H THEN up := TRUE
      ELSIF b = 0E0H THEN ext := TRUE
      ELSE
        IF ext THEN dk := tabE[b] ELSE dk := tabN[b] END ;
        IF dk # 0 THEN
          IF up THEN keyin(dk * 100H) ELSE keyin(dk * 100H + 1) END
        END ;
        up := FALSE; ext := FALSE
      END
    END
  END PollKeys;

  (*repaint the desktop DOOM scribbled over: viewer state lives in the heap, only
    pixels were lost — one restore broadcast redraws every frame and filler*)
  PROCEDURE Restore;
    VAR M: Viewers.ViewerMsg;
  BEGIN M.id := Viewers.restore; Viewers.Broadcast(M)
  END Restore;

  PROCEDURE Run0(hw: BOOLEAN);
    VAR blobLen, wadLen, len, i, a, w, r, st: INTEGER;
      name: ARRAY 16 OF CHAR;
  BEGIN
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
        (*feat/indexbuf (draft seam): SHARED +544 bit 0 advertises the hardware
          scanout ditherer; the blob then composites into the Indexbuf window
          and skips the software dither. Only meaningful on a bitstream that
          carries Indexbuf — on the stock bitstream RunHW plays blind (desktop
          stays; use Run)*)
        IF hw THEN SYSTEM.PUT(SharedBase + 544, 1) END ;
        CopyArgs;
        SYSTEM.GET(BlobBase + 20, w); SYSTEM.PUT(SYSTEM.ADR(init), BlobBase + w);
        SYSTEM.GET(BlobBase + 24, w); SYSTEM.PUT(SYSTEM.ADR(tick), BlobBase + w);
        SYSTEM.GET(BlobBase + 28, w); SYSTEM.PUT(SYSTEM.ADR(keyin), BlobBase + w);
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

BEGIN Texts.OpenWriter(W); up := FALSE; ext := FALSE; InitTables
END DOOM.
