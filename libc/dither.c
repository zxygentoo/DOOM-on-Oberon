/* dither.c — the 1-bit ordered-dither blit kernel (AGENT.md §5, the DG_ port
 * slice). Pure memory -> memory: no MMIO, no DOOM externs, no includes — so
 * the WHOLE file rides the differential jig as oracle-side source too, and
 * the exact code shipping in the blob is diffed against host gcc. That is
 * 1d's "same dither code, bit-identical" contract, started at the function
 * level two milestones early.
 *
 * The pipeline: palette -> 256-byte luminance LUT (ITU-601 weights; gamma is
 * already folded in, I_SetPalette applies gammatable as it fills colors[]) ->
 * threshold against a 4x4 Bayer matrix -> 1-bit output, 2x2 pixel-doubled.
 * ONE dither decision per SOURCE pixel (§5's budget: ~64k decisions/frame):
 * the bit doubles into both output columns and the packed word stores to both
 * output lines. The result is a 320x200 dither pattern, pixel-doubled — the
 * Playdate look; dithering the doubled columns separately is the (2x cost)
 * quality knob if 1d's framebuffer dumps disappoint. */

static unsigned char __dg_lum[256];

/* thresholds m*16+8 over the 0..255 luminance scale, from the classic 4x4
 * Bayer matrix (0,8,2,10 / 12,4,14,6 / 3,11,1,9 / 15,7,13,5): luminance 0 is
 * always black, 255 always white */
static const unsigned char __dg_bayer[16] = {
    8, 136, 40, 168, 200, 72, 232, 104, 56, 184, 24, 152, 248, 120, 216, 88,
};

/* Rebuild the LUT from a 256-entry BGRA byte palette — the raw bytes of
 * i_video's struct color[256]: b at +0, g at +1, r at +2 (the byte-aligned :8
 * little-endian layout the jig's bf1 sample pins). Weights sum to 256, so
 * full white maps to 255 exactly. */
void __dg_build_lut(const unsigned char *pal)
{
    int i;
    for (i = 0; i < 256; i++) {
        __dg_lum[i] = (unsigned char)((77 * pal[4 * i + 2] + 150 * pal[4 * i + 1]
                                       + 29 * pal[4 * i]) >> 8);
    }
}

/* Dither-blit [w x h] palette indices ([w] a multiple of 16) as a 2x2-doubled
 * 1-bit image. [dst] is the word holding the rect's top-left in SCREEN
 * coordinates; [stride] is words per screen line DOWNWARD; bit 0 of a word is
 * its LEFTMOST pixel (the Oberon convention). Oberon's framebuffer is
 * BOTTOM-UP, so the machine caller passes stride -32 (1024 px = 32-word
 * lines, upward in memory); the jig passes small positive strides into plain
 * arrays — the vertical flip is a parameter, not a special case. */
void __dg_dither(const unsigned char *src, int w, int h, unsigned int *dst, int stride)
{
    int x, y, k;
    for (y = 0; y < h; y++) {
        const unsigned char *thr = __dg_bayer + 4 * (y & 3);
        unsigned int *out = dst;
        for (x = 0; x < w; x += 16) {
            unsigned int bits = 0;
            for (k = 0; k < 16; k++) {
                /* source x = x + k, and x is a multiple of 16, so the Bayer
                   column is just k & 3 */
                if (__dg_lum[src[x + k]] > thr[k & 3])
                    bits |= 3u << (2 * k);
            }
            out[0] = bits;
            out[stride] = bits;
            out = out + 1;
        }
        src += w;
        dst += 2 * stride;
    }
}
