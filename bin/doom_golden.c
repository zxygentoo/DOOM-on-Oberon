/* doom_golden.c — the headless golden-frame generator (AGENT.md 1d).
 *
 * The host half of the visual-golden oracle: the same game, the same WAD, the
 * same -timedemo demo1, and — the load-bearing part — THE SAME libc/dither.c,
 * blitting CMAP256 320x200 frames into a fake 1024x768 1-bit framebuffer with
 * the exact machine geometry (origin word 583*32+6, stride -32). At chosen
 * gametics the raw fb window (32*768 little-endian words, memory order — fb
 * line 0 at the bottom, bit 0 leftmost) dumps to golden_gNNNNN.fbw; 
 * -dump-at writes the identical format from emulator RAM, and cmp(1) is the
 * verdict: bit-identical or the toolchain/port diverged.
 *
 * Alignment needs no game-memory access on either side: under -timedemo the
 * engine is singletics, so after doomgeneric_Create (which runs init + ONE
 * tic) gametic = 1, and after the t-th doomgeneric_Tick gametic = t + 1 —
 * both sides just count Tick calls. Choose gametics away from the demo-start
 * wipe (whose multiple renders per gametic depend on the pacing clock; from
 * ~gametic 100 on, render <-> gametic is 1:1).
 *
 * Build: `make golden` (top-level Makefile) — gcc -m32 -funsigned-char
 * (the jig oracle's target model), no SDL, no sound.
 *
 * Usage: `make goldens` (or GOLDEN_TICS=... ./golden in _out/golden; defaults
 * to that list — frames land next to the binary) */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#include "doomgeneric.h"
#include "i_video.h"

/* the shipped kernel, compiled for the host by plain gcc */
extern void __dg_build_lut(const unsigned char *pal);
extern void __dg_dither_fs(const unsigned char *src, unsigned int *dst, int stride);

#define FB_WORDS (32 * 768)
static unsigned int fb[FB_WORDS];

/* mirror of the blob's DG_DrawFrame wrapper (libc/doom_oberon.c),
   byte for byte in effect: LUT-on-palette_changed, then the fullscreen blit
   (screen top-left = fb word 767*32, stride -32 — fb bottom-up) */
void DG_DrawFrame(void)
{
    if (palette_changed) {
        __dg_build_lut((const unsigned char *)colors);
        palette_changed = 0;
    }
    __dg_dither_fs(DG_ScreenBuffer, fb + 767 * 32, -32);
}

void DG_Init(void) { }
void DG_SleepMs(uint32_t ms) { (void)ms; }

uint32_t DG_GetTicksMs(void)
{
    /* synthetic, monotonic, reproducible; under singletics only the wipe and
       the closing realtics count consult it, neither of which is compared */
    static uint32_t t = 0;
    t += 10;
    return t;
}

/* ---- scripted input + scene capture (the dither-lab side doors; all three
 * are env-gated and default OFF, so the golden path stays byte-identical) ----
 *
 * GOLDEN_KEYS=tick:doomkey:pressed,...  feed key events before that Tick
 * GOLDEN_SCENES=tick:name,...           dump DG_ScreenBuffer (64000 B of
 *                                        320x200 palette indices) to
 *                                        scene_<name>.sbuf and colors[] (1024
 *                                        BGRA bytes, gamma pre-applied) to
 *                                        scene_<name>.pal after that Tick
 * GOLDEN_ARGS=-warp 1                    replace "-timedemo demo1"           */

static int key_q[256][3]; /* tick, doomkey, pressed */
static int key_n, key_cursor, tick_now;

int DG_GetKey(int *pressed, unsigned char *doomKey)
{
    if (key_cursor < key_n && key_q[key_cursor][0] <= tick_now) {
        *doomKey = (unsigned char)key_q[key_cursor][1];
        *pressed = key_q[key_cursor][2];
        key_cursor++;
        return 1;
    }
    return 0;
}

static void capture_scene(const char *name)
{
    char fn[80];
    FILE *f;
    snprintf(fn, sizeof fn, "scene_%s.sbuf", name);
    f = fopen(fn, "wb");
    if (!f || fwrite(DG_ScreenBuffer, 1, 320 * 200, f) != 320 * 200) {
        fprintf(stderr, "golden: cannot write %s\n", fn);
        exit(2);
    }
    fclose(f);
    snprintf(fn, sizeof fn, "scene_%s.pal", name);
    f = fopen(fn, "wb");
    if (!f || fwrite(colors, 1, 1024, f) != 1024) {
        fprintf(stderr, "golden: cannot write %s\n", fn);
        exit(2);
    }
    fclose(f);
    fprintf(stderr, "golden: tick %d -> scene_%s.{sbuf,pal}\n", tick_now, name);
}

void DG_SetWindowTitle(const char *title) { (void)title; }

static void dump(int gametic_now)
{
    char name[64];
    FILE *f;
    snprintf(name, sizeof name, "golden_g%05d.fbw", gametic_now);
    f = fopen(name, "wb");
    if (!f || fwrite(fb, 4, FB_WORDS, f) != FB_WORDS) {
        fprintf(stderr, "golden: cannot write %s\n", name);
        exit(2);
    }
    fclose(f);
    fprintf(stderr, "golden: gametic %d -> %s\n", gametic_now, name);
}

static int scene_tick[64];
static char scene_name[64][32];
static int scene_n;

int main(int argc, char **argv)
{
    int targets[64];
    int n = 0;
    const char *spec = getenv("GOLDEN_TICS");
    const char *keys = getenv("GOLDEN_KEYS");
    const char *scenes = getenv("GOLDEN_SCENES");
    const char *dargs = getenv("GOLDEN_ARGS");
    char *end;
    int t;
    (void)argc;
    (void)argv;
    if (!spec) spec = "100,1000,2500,5000";
    while (n < 64) {
        long v = strtol(spec, &end, 10);
        if (end == spec) break;
        targets[n++] = (int)v;
        spec = (*end == ',') ? end + 1 : end;
    }
    while (keys && key_n < 256) {
        long a = strtol(keys, &end, 10);
        if (end == keys || *end != ':') break;
        keys = end + 1;
        long b = strtol(keys, &end, 10);
        if (end == keys || *end != ':') break;
        keys = end + 1;
        long c = strtol(keys, &end, 10);
        if (end == keys) break;
        key_q[key_n][0] = (int)a;
        key_q[key_n][1] = (int)b;
        key_q[key_n][2] = (int)c;
        key_n++;
        keys = (*end == ',') ? end + 1 : end;
    }
    while (scenes && scene_n < 64) {
        long a = strtol(scenes, &end, 10);
        if (end == scenes || *end != ':') break;
        scenes = end + 1;
        int i = 0;
        while (*scenes && *scenes != ',' && i < 31) scene_name[scene_n][i++] = *scenes++;
        scene_name[scene_n][i] = 0;
        scene_tick[scene_n] = (int)a;
        scene_n++;
        if (*scenes == ',') scenes++;
    }
    {
        char *args[64] = { "doom", "-iwad", "doom1.wad", "-timedemo", "demo1" };
        int argn = 5;
        static char abuf[256];
        if (dargs) {
            argn = 3;
            snprintf(abuf, sizeof abuf, "%s", dargs);
            char *p = abuf;
            while (*p && argn < 64) {
                while (*p == ' ') p++;
                if (!*p) break;
                args[argn++] = p;
                while (*p && *p != ' ') p++;
                if (*p) *p++ = 0;
            }
        }
        doomgeneric_Create(argn, args);
    }
    /* gametic = t + 1 after the t-th Tick; the demo's I_Error exits for us
       (scripted GOLDEN_KEYS quit runs land here too, via exit()) */
    for (t = 0; t < 6000; t++) {
        int k;
        tick_now = t;
        for (k = 0; k < n; k++)
            if (targets[k] == t + 1) dump(t + 1);
        /* scenes share GOLDEN_TICS' gametic numbering (pre-Tick, t + 1), so
           GOLDEN_SCENES=1000:game pairs bit-exactly with golden_g01000.fbw */
        for (k = 0; k < scene_n; k++)
            if (scene_tick[k] == t + 1) capture_scene(scene_name[k]);
        doomgeneric_Tick();
    }
    fprintf(stderr, "golden: demo never ended (6000 ticks)\n");
    return 3;
}
