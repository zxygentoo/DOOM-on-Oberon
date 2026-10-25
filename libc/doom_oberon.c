/* doom_oberon.c — the doomgeneric platform layer for the Oberon RISC5 machine,
 * in upstream's doomgeneric_<platform>.c slot: the six DG_ hooks, the key ring, the
 * DG_DrawFrame wrapper over dither.c's kernel and the Halftone path, the three
 * ABI §7 blob entries (Init/Tick/KeyIn), and a setjmp-shaped exit().
 *
 * Plain C, preprocessor-free like mini.c: no includes, types spelled as the
 * host-preprocessed .i files spell them (uint32_t = unsigned int, ILP32).
 *
 * The machine surface:
 *   - the millisecond counter, MMIO at 0xFFFFFFC0 — the sign-extended form of the
 *     24-bit 0xFFFFC0, as with stdio.c's UART at 0xFFFFFFC8/CC (a mem-op computes
 *     its address in 32 bits; the bus and the emulator agree on that spelling);
 *   - the SHARED page (ABI §8): status, heartbeat, presentation flags, the command
 *     tail, and the key ring — head u32 at +20, tail u32 at +24, 256 two-byte events
 *     at +32: byte 0 = pressed (1 make, 0 break), byte 1 = doomkey. i_input.c's
 *     TranslateKey is the identity, so the sender owns all translation and the
 *     blob never sees a scancode;
 *   - the framebuffer, and the Halftone window when the loader advertises it.
 *
 * [__shared_base] and [__fb_base] are externs the environment defines (doom_heap.c
 * on the machine, the jig inside emulator RAM), like mini.c's heap bounds. */

typedef unsigned int uint32_t;

extern char *__shared_base;

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
       Spinning is the sleep: nothing else needs the CPU meanwhile (and the
       emulator detects this ms-counter spin and yields to its frame loop). */
    while (DG_GetTicksMs() - start < ms) { }
}

/* The key ring, single producer and single consumer. Head and tail are
 * free-running u32 counters masked at use (index = counter & 255): empty is
 * head == tail, full is head - tail == 256, and the arithmetic stays correct
 * across the u32 rollover. KeyIn (via DG_KeyEnqueue) bumps head; DG_GetKey,
 * called from I_GetEvent's drain loop, bumps tail. Both start at 0: the stub
 * zeroes the page. */

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

/* A full ring drops the event: 256 queued keystrokes outlast any human, and
 * dropping beats corrupting the ring. */
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

/* Video. doomgeneric renders 320x200 palette indices into DG_ScreenBuffer (RESX/RESY
 * are pinned to 320x200 at preprocess time, so fb_scaling = 1, and patch 0003 makes
 * it I_VideoBuffer itself, so I_FinishUpdate copies nothing) and calls DG_DrawFrame.
 * The kernel lives in dither.c; this wrapper owns the DOOM-side globals and the
 * machine geometry:
 *   - colors[256] (BGRA bytes in memory — the byte-aligned :8 layout) is refilled
 *     by I_SetPalette on every palette switch, gamma applied; palette_changed
 *     signals it, and the one LUT is rebuilt (the next frame dithers through the
 *     new palette, which is the visible flash);
 *   - the software target is the whole 1024x768 panel (3.2 x 3.84 = DOOM's 4:3 CRT
 *     aspect). Oberon's framebuffer is bottom-up (screen line y is fb line 767-y,
 *     bit 0 leftmost), so the screen's top-left word is fb word 767*32 and the
 *     stride is -32 words per screen line. Every fb word is written each frame. */

struct color {
    uint32_t b:8;
    uint32_t g:8;
    uint32_t r:8;
    uint32_t a:8;
};

extern struct color colors[256];
extern unsigned int palette_changed;    /* i_video's boolean */
extern unsigned char *DG_ScreenBuffer;
extern char *__fb_base;                 /* doom_heap.c binds 0xE7F00 */

extern void __dg_build_lut(const unsigned char *pal);
extern void __dg_dither_fs(const unsigned char *src, unsigned int *dst, int stride);

/* The Halftone path (ABI.md §11; the hardware is the host repo's Halftone): a
 * 64 KiB window at HT_BASE that the board shadows into BRAM and dithers at scanout
 * — pixels at +0 (each finished frame is copied there), the 256-byte luminance LUT
 * at +64000, the control word (bit 0 = mode) at +64256. The loader advertises the
 * hardware in SHARED +544 bit 0; a zeroed page means the software dither. Mode goes
 * on at the first frame — never at Init, or the panel would scan out an
 * uninitialized buffer through D_DoomMain's long init — and off in exit(), which
 * brings the desktop back at once (the mono framebuffer was never touched). */

enum { HT_BASE = 0x310000, HT_LUT = 0x310000 + 64000, HT_CTL = 0x310000 + 64256 };

extern unsigned char __dg_lum[256];      /* dither.c's LUT (filled by __dg_build_lut) */
extern unsigned char *__dg_fixed_vbuf;   /* i_video.c (patch 0004): fixed buffer placement */
extern void __dg_upload_thresholds(void);/* dither.c: DOOM's blue noise -> the threshold window */
extern void __dg_upload_geometry(void); /* dither.c: the out2 row map + rect/scale registers */

static unsigned int __dg_hw;             /* SHARED +544 bit 0, latched by DG_Init */
static unsigned int __dg_hw_viewer;      /* +544 bit 1: viewer presentation — the stub
                                            owns mode + geometry; the blob keeps only
                                            thresholds + LUT + frame copy */
static unsigned int __dg_hw_on;          /* mode written once, at the first frame */

extern void __dg_frame_copy(const unsigned char *src, unsigned char *dst);

void DG_DrawFrame(void)
{
    if (__dg_hw) {
        /* copy the finished frame into the window: the double buffer DOOM's
           renderer assumes. Rendering straight into the window let the raster
           show R_RenderPlayerView mid-sweep (flicker at the render rate on the
           board); with the copy the panel only ever scans complete frames. */
        __dg_frame_copy(DG_ScreenBuffer, (unsigned char *)HT_BASE);
        if (palette_changed) {
            int i;
            __dg_build_lut((const unsigned char *)colors);
            for (i = 0; i < 256; i++)
                ((volatile unsigned char *)HT_LUT)[i] = __dg_lum[i];
            palette_changed = 0;
        }
        if (!__dg_hw_on) {
            /* the hardware powers up with zero tables and a zero-sized rect:
               upload the thresholds, plus (fullscreen) the row map and geometry,
               before the mode goes on. The registers latch at the next vblank,
               so the desktop lingers at most one frame. */
            __dg_upload_thresholds();
            if (!__dg_hw_viewer) {
                __dg_upload_geometry();
                *(volatile unsigned int *)HT_CTL = 1;
            }
            __dg_hw_on = 1;
        }
        return;
    }
    if (palette_changed) {
        __dg_build_lut((const unsigned char *)colors);
        palette_changed = 0;
    }
    __dg_dither_fs(DG_ScreenBuffer, (unsigned int *)__fb_base + 767 * 32, -32);
}

void DG_SetWindowTitle(const char *title)
{
    (void)title;
}

extern int printf(const char *fmt, ...);

void DG_Init(void)
{
    /* The compositing buffer stays zone-allocated in hardware mode too (see
       DG_DrawFrame's copy). __dg_fixed_vbuf (patch 0004) stays unset: it is the
       seam a hardware double-buffer would use. */
    __dg_hw = *(volatile unsigned int *)(__shared_base + 544) & 1;
    __dg_hw_viewer = (*(volatile unsigned int *)(__shared_base + 544) >> 1) & 1;
    __dg_hw_on = 0;
    printf("DOOM on Oberon: blob alive\n");
}

/* The blob entries (ABI §7) and exit(). doomgeneric's D_DoomLoop runs the graphics init plus ONE tick and
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

/* The DOOM command line (ABI §8, SHARED +1024): the loader writes the raw command
 * tail verbatim — DOOM.Mod copies the rest of the command's line, run_blob its
 * -args string; no parsing happens on the loader side.
 * Init prepends the three baked words and tokenizes the tail on blanks IN
 * PLACE (the split writes the NULs), so the region belongs to the blob after
 * Init and myargv's pointers stay valid: the SHARED page persists. A zeroed
 * page (the stub's obligation) is the empty tail — argc stays 3. */
enum { ARGV_MAX = 16 };   /* Frontc parses these files cpp-free: no #define */

static char *__argv[ARGV_MAX] = { "doom", "-iwad", "doom1.wad" };

/* Non-static so the jig can test it directly. */
int __parse_cmdline(char *s, char **argv, int argc, int max)
{
    for (;;) {
        while (*s == ' ' || *s == '\t') s++;
        if (*s == 0 || argc >= max) return argc;
        argv[argc] = s;
        argc++;
        while (*s && *s != ' ' && *s != '\t') s++;
        if (*s) { *s = 0; s++; }
    }
}

void exit(int status)
{
    /* hardware scanout off first: the mono framebuffer was never written, so
       the desktop reappears the instant the mode bit drops */
    if (__dg_hw && !__dg_hw_viewer) {
        *(volatile unsigned int *)HT_CTL = 0;
        __dg_hw_on = 0;
    }
    /* SHARED +12 (ABI §8): 0 running, 1 clean quit, negative = I_Error code */
    *(volatile int *)(__shared_base + 12) = status == 0 ? 1 : status;
    __longjmp(__exit_env, 1);
}

int Init(int wad_addr, int cfg_addr)
{
    (void)cfg_addr;   /* the SHARED page, reached through __shared_base instead */
    if (__setjmp(__exit_env))
        return *(volatile int *)(__shared_base + 12);   /* I_Error during init */
    /* the WAD arrives as a pointer + length (SHARED +28), never as storage;
       -iwad pins the exact name D_FindWADByName will fopen */
    __file_register("doom1.wad", (const void *)wad_addr,
                    *(volatile unsigned int *)(__shared_base + 28));
    doomgeneric_Create(__parse_cmdline(__shared_base + 1024, __argv, 3, ARGV_MAX),
                       __argv);
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
