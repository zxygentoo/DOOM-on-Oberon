/* heap_doom.c — the malloc arena bounds for the real machine (ABI §8).
 *
 * mini.c's bump allocator reads [__heap_base, __heap_end); this file binds them to
 * himem: the spare row (0x320000, wipe buffers / LUTs / growth) plus the zone row
 * (0x400000, DOOM's 6 MB Z_Malloc block arrives as ONE malloc from I_ZoneBase) —
 * 6.875 MB in all, served bump-style. The jig binds its own bounds instead (a sample
 * defines the two globals inside emulator RAM). */

char *__heap_base = (char *)0x320000;
char *__heap_end = (char *)0xA00000;
