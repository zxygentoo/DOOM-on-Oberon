/* doom_heap.c — the himem address bindings for the real machine (ABI §8).
 *
 * mini.c's bump allocator reads [__heap_base, __heap_end); this file binds them to
 * himem: the spare row (0x320000, wipe buffers / LUTs / growth) plus the zone row
 * (0x400000, DOOM's 6 MB Z_Malloc block arrives as ONE malloc from I_ZoneBase) —
 * 6.875 MB in all, served bump-style. doom_oberon.c's key ring reads
 * [__shared_base], the SHARED page. The jig binds its own addresses instead (a
 * sample defines the globals inside emulator RAM). */

char *__heap_base = (char *)0x320000;
char *__heap_end = (char *)0xA00000;
char *__shared_base = (char *)0x300000;
char *__fb_base = (char *)0xE7F00; /* the 1024x768x1 framebuffer (bottom-up) */
