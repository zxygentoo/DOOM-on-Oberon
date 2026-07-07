/* doomgeneric_oberon.c — the doomgeneric platform layer for the Oberon RISC5
 * machine (AGENT.md §7, the DG_ port slice). Named the way upstream names its
 * platforms (doomgeneric_sdl.c, doomgeneric_allegro.c, ...). This sub-slice:
 * the four trivial hooks + the key-ring producer. DG_Init, DG_DrawFrame (the
 * dither-blit) and the Init/Tick/KeyIn entries land in later sub-slices.
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

/* ---- chrome ---- */

void DG_SetWindowTitle(const char *title)
{
    (void)title;   /* locked decision (AGENT.md §2.4): set-title is a no-op */
}
