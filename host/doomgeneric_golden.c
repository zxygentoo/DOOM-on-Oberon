/* doomgeneric_golden.c — the headless golden-frame generator (AGENT.md 1d).
 *
 * The host half of the visual-golden oracle: the same game, the same WAD, the
 * same -timedemo demo1, and — the load-bearing part — THE SAME libc/dither.c,
 * blitting CMAP256 320x200 frames into a fake 1024x768 1-bit framebuffer with
 * the exact machine geometry (origin word 583*32+6, stride -32). At chosen
 * gametics the raw fb window (32*768 little-endian words, memory order — fb
 * line 0 at the bottom, bit 0 leftmost) dumps to golden_gNNNNN.fbw; doomrun's
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
 * Build: the `golden` target in host/Makefile — gcc -m32 -funsigned-char
 * (the jig oracle's target model), no SDL, no sound.
 *
 * Usage: GOLDEN_TICS=100,1000,2500,5000 ./golden  (defaults to that list) */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#include "doomgeneric.h"
#include "i_video.h"

/* the shipped kernel, compiled for the host by plain gcc */
extern void __dg_build_lut(const unsigned char *pal);
extern void __dg_dither(const unsigned char *src, int w, int h, unsigned int *dst,
                        int stride);

#define FB_WORDS (32 * 768)
static unsigned int fb[FB_WORDS];

/* mirror of the blob's DG_DrawFrame wrapper (libc/doomgeneric_oberon.c),
   byte for byte in effect: LUT-on-palette_changed, then the machine blit */
void DG_DrawFrame(void)
{
    if (palette_changed) {
        __dg_build_lut((const unsigned char *)colors);
        palette_changed = 0;
    }
    __dg_dither(DG_ScreenBuffer, 320, 200, fb + (583 * 32 + 6), -32);
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

int DG_GetKey(int *pressed, unsigned char *doomKey)
{
    (void)pressed;
    (void)doomKey;
    return 0;
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

int main(int argc, char **argv)
{
    int targets[64];
    int n = 0;
    const char *spec = getenv("GOLDEN_TICS");
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
    {
        char *args[] = { "doom", "-iwad", "doom1.wad", "-timedemo", "demo1" };
        doomgeneric_Create(5, args);
    }
    /* gametic = t + 1 after the t-th Tick; the demo's I_Error exits for us */
    for (t = 0; t < 6000; t++) {
        int k;
        for (k = 0; k < n; k++)
            if (targets[k] == t + 1) dump(t + 1);
        doomgeneric_Tick();
    }
    fprintf(stderr, "golden: demo never ended (6000 ticks)\n");
    return 3;
}
