/* doom_heap.c — the himem address bindings for the real machine (ABI §8).
 *
 * mini.c's bump allocator reads [__heap_base, __heap_end): the spare row (0x320000,
 * wipe buffers, LUTs, growth) plus the zone row (0x400000 — DOOM's 6 MB zone
 * arrives as one malloc from I_ZoneBase), 6.875 MB in all. doom_oberon.c reads
 * [__shared_base] and [__fb_base]. The jig defines these globals itself, inside
 * emulator RAM. */

char *__heap_base = (char *)0x320000;
char *__heap_end = (char *)0xA00000;
char *__shared_base = (char *)0x300000;
char *__fb_base = (char *)0xE7F00; /* the 1024x768x1 framebuffer (bottom-up) */
