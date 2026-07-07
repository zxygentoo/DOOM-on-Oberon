/* doomgeneric_oberon.c — the doomgeneric platform layer for the Oberon RISC5
 * machine (AGENT.md §7, the DG_ port slice — complete). Named the way upstream
 * names its platforms (doomgeneric_sdl.c, doomgeneric_allegro.c, ...): all six
 * DG_ hooks, the key-ring producer, the DG_DrawFrame dither-blit wrapper
 * (kernel in dither.c), the three ABI §7 blob entries (Init/Tick/KeyIn), and
 * the setjmp-shaped exit().
 *
 * Plain C, preprocessor-free (mini.c's rules): no includes, types spelled as
 * the host-preprocessed .i files spell them (uint32_t = unsigned int, ILP32).
 *
 * The machine surface is two things only:
 *   - the millisecond counter, MMIO at 0xFFFFFFC0 — the sign-extended form of
 *     the 24-bit 0xFFFFC0, the same convention as stdio.c's UART at
 *     0xFFFFFFC8/CC (a mem-op computes its address in 32 bits; the bus and
 *     the emulator decode agree on the sign-extended spelling);
 *   - the SHARED-page key ring (ABI §8): head u32 at +20, tail u32 at +24,
 *     256 two-byte events at +32. Event = the §6 wire framing verbatim:
 *     byte 0 = pressed (1 make, 0 break), byte 1 = doomkey code — i_input.c's
 *     TranslateKey is the identity, so the SENDER owns all translation and
 *     the blob never sees a scancode table.
 *
 * [__shared_base] is the SHARED page address, an extern the ENVIRONMENT
 * defines (heap_doom.c binds ABI §8's 0x300000; the jig binds a spot inside
 * emulator RAM) — the same pattern as mini.c's heap bounds. */

typedef unsigned int uint32_t;

extern char *__shared_base;

/* ---- time: the ms counter ---- */

uint32_t DG_GetTicksMs(void)
{
    /* one fresh LDW per call: naive codegen never caches memory in a
       register, so volatile holds by construction (same story as the UART
       busy-wait) — a future caching allocator must learn the qualifier */
    return *(volatile uint32_t *)0xFFFFFFC0;
}

void DG_SleepMs(uint32_t ms)
{
    uint32_t start = DG_GetTicksMs();
    /* unsigned subtraction is wrap-correct across the counter rollover.
       Spinning IS the sleep: v1 is the fullscreen seize, DOOM is the
       machine's only occupant (and the emulator detects exactly this
       ms-counter idle-spin and yields to its host frame loop). */
    while (DG_GetTicksMs() - start < ms) { }
}

/* ---- keys: the SHARED-page ring (single producer, single consumer) ----
 *
 * Head and tail are free-running u32 counters masked at use (index =
 * counter & 255): empty is head == tail, full is head - tail == 256, and
 * the wrap arithmetic stays correct across the u32 rollover. The producer
 * (the stub's KeyIn / the UART poll, later sub-slices via DG_KeyEnqueue)
 * bumps head; the consumer (DG_GetKey, called from I_GetEvent's drain
 * loop) bumps tail. Head/tail start equal: the stub zeroes the page. */

int DG_GetKey(int *pressed, unsigned char *key)
{
    volatile uint32_t *head = (volatile uint32_t *)(__shared_base + 20);
    volatile uint32_t *tail = (volatile uint32_t *)(__shared_base + 24);
    volatile unsigned char *ring = (volatile unsigned char *)(__shared_base + 32);
    uint32_t t = *tail;
    if (t == *head)
        return 0;
    *pressed = ring[2 * (t & 255)];
    *key = ring[2 * (t & 255) + 1];
    *tail = t + 1;
    return 1;
}

/* The producer half — KeyIn's core (the ABI §7 entry unpacks its event word
 * into this). A full ring drops the event: 256 queued keystrokes outlast any
 * human, and dropping beats corrupting the ring. */
void DG_KeyEnqueue(int pressed, unsigned char key)
{
    volatile uint32_t *head = (volatile uint32_t *)(__shared_base + 20);
    volatile uint32_t *tail = (volatile uint32_t *)(__shared_base + 24);
    volatile unsigned char *ring = (volatile unsigned char *)(__shared_base + 32);
    uint32_t h = *head;
    if (h - *tail == 256)
        return;
    ring[2 * (h & 255)] = (unsigned char)(pressed != 0);
    ring[2 * (h & 255) + 1] = key;
    *head = h + 1;
}

/* ---- video: the dither-blit wrapper (AGENT.md §5) ----
 *
 * doomgeneric fills DG_ScreenBuffer (320x200 palette indices — RESX/RESY are
 * pinned to 320x200 at preprocess time, so fb_scaling = 1 and I_FinishUpdate
 * is a straight per-line copy) and calls DG_DrawFrame. The dither pipeline —
 * luminance LUT + 4x4 Bayer + 2x2-doubled 1-bit packing — lives in dither.c
 * (pure memory->memory, jig-diffed against host gcc); this wrapper owns the
 * DOOM-side globals and the machine geometry:
 *   - colors[256] (BGRA bytes in memory — the byte-aligned :8 layout) is
 *     refilled by I_SetPalette on every palette switch, gamma pre-applied;
 *     palette_changed signals it and the LUT rebuilds — §5's "14 precomputed
 *     LUTs" simplified to one-LUT-on-change (the next frame dithers through
 *     the new palette, which is the visible flash);
 *   - the target rect: 640x400 centered on the 1024x768 1-bit framebuffer.
 *     Origin = screen (192,184); Oberon's framebuffer is BOTTOM-UP (screen
 *     line y lives at fb line 767-y, bit 0 leftmost), so the top-left word is
 *     fb word (767-184)*32 + 192/32 = 583*32 + 6 and the stride is -32 words
 *     per screen line. Everything word-aligned: 192 px = 6 words, 640 = 20. */

struct color {
    uint32_t b:8;
    uint32_t g:8;
    uint32_t r:8;
    uint32_t a:8;
};

extern struct color colors[256];
extern unsigned int palette_changed;    /* i_video's boolean */
extern unsigned char *DG_ScreenBuffer;
extern char *__fb_base;                 /* heap_doom.c binds 0xE7F00 */

extern void __dg_build_lut(const unsigned char *pal);
extern void __dg_dither(const unsigned char *src, int w, int h, unsigned int *dst,
                        int stride);

void DG_DrawFrame(void)
{
    if (palette_changed) {
        __dg_build_lut((const unsigned char *)colors);
        palette_changed = 0;
    }
    __dg_dither(DG_ScreenBuffer, 320, 200,
                (unsigned int *)__fb_base + (583 * 32 + 6), -32);
}

/* ---- chrome ---- */

void DG_SetWindowTitle(const char *title)
{
    (void)title;   /* locked decision (AGENT.md §2.4): set-title is a no-op */
}

extern int printf(const char *fmt, ...);

void DG_Init(void)
{
    /* nothing to bring up — no fb mode-set, the key ring is stub-zeroed, the
       timer free-runs; the banner is the earliest proof of the console path */
    printf("DOOM on Oberon: blob alive\n");
}

/* ---- the blob entries (ABI §7) + exit ----
 *
 * doomgeneric's patched D_DoomLoop runs the graphics init plus ONE tick and
 * RETURNS — so Init genuinely comes back, and Tick is one clean frame. The
 * only non-returning path is exit(): I_Quit -> atexit chain -> exit(0),
 * I_Error -> message (already on the UART) -> exit(-1), both at arbitrary
 * call depth. exit() stores the §8 status word and __longjmp-unwinds to an
 * env armed at the CURRENT entry's prologue — re-armed on every entry,
 * because the env of a returned entry points into a dead frame. */

extern void doomgeneric_Create(int argc, char **argv);
extern void doomgeneric_Tick(void);
extern void __file_register(const char *name, const void *base, unsigned long size);
extern int __setjmp(unsigned int *env);
extern void __longjmp(unsigned int *env, int val);

/* nine words: R6-R12, SP, LNK (Runtime's jmp_buf). Non-static so the jig can
   arm it directly when testing exit(). */
unsigned int __exit_env[9];

static char *__argv[3] = { "doom", "-iwad", "doom1.wad" };

void exit(int status)
{
    /* SHARED +12 (ABI §8): 0 running, 1 clean quit, negative = I_Error code */
    *(volatile int *)(__shared_base + 12) = status == 0 ? 1 : status;
    __longjmp(__exit_env, 1);
}

int Init(int wad_addr, int cfg_addr)
{
    (void)cfg_addr;   /* v1: the cfg page IS the §8 SHARED page, reached via
                         the baked __shared_base binding like all shared traffic */
    if (__setjmp(__exit_env))
        return *(volatile int *)(__shared_base + 12);   /* I_Error during init */
    /* the §2.7 moment: the WAD arrives as a pointer + length (SHARED +28),
       never as storage; -iwad pins the exact name D_FindWADByName will fopen */
    __file_register("doom1.wad", (const void *)wad_addr,
                    *(volatile unsigned int *)(__shared_base + 28));
    doomgeneric_Create(3, __argv);
    return 0;
}

int Tick(void)
{
    if (__setjmp(__exit_env))
        return 1;                     /* exit() unwound; status already set */
    doomgeneric_Tick();
    *(volatile unsigned int *)(__shared_base + 16) += 1;   /* heartbeat */
    return 0;
}

void KeyIn(int ev)
{
    /* ev = pressed | doomkey << 8 — the §6 wire / §8 ring byte order */
    DG_KeyEnqueue(ev & 0xFF, (unsigned char)((ev >> 8) & 0xFF));
}
