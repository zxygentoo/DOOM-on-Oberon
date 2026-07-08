/* mini.c — the mini-libc (AGENT.md 1c), part 1: the no-varargs core.
 *
 * Plain C, preprocessor-free (no includes: it parses directly and owns its types —
 * size_t is unsigned int under ILP32), compiled by doomcc like any other translation
 * unit and merged by Mergecil. Every function here is differential-jig-tested against
 * the host's real glibc: our memcpy, compiled by our backend, running in the emulator,
 * diffed against the genuine article.
 *
 * The heap is a bump allocator over [__heap_base, __heap_end) — two extern globals the
 * ENVIRONMENT defines, because the bounds differ per world: the jig's emulator RAM vs
 * ABI §8's arena (libc/heap_doom.c). free() is a no-op: DOOM zone-allocates internally
 * out of one big block, and the few real malloc sites never free-and-reuse at a scale
 * that matters (the plan's "one-big-block malloc").
 *
 * Deferred to later slices: the printf family (needs the varargs compiler slice),
 * fopen/fread & co (the memory-backed w_file over the preloaded WAD). */

/* size_t, textually as the host-preprocessed .i files typedef it (unsigned long —
 * 32-bit under our ILP32 machdep): Mergecil unifies types STRUCTURALLY BY NAME, so a
 * plain `unsigned` here would be "two distinct globals" against the tree's glibc
 * prototypes. */
typedef unsigned long size_t;

/* ---- mem* ---- */

void *memcpy(void *dst, const void *src, size_t n)
{
    char *d = dst;
    const char *s = src;
    /* Word fast path — the 1d flat profile found the byte loop carrying 22%
     * of every frame (I_FinishUpdate's 64 KB screen copy and friends, ~5
     * instrs/byte). Bulk copies in DOOM are word-aligned in practice; when
     * both pointers are, move 4 bytes per iteration and leave the tail (and
     * any unaligned call) to the byte loop below. */
    if ((((unsigned)d | (unsigned)s) & 3u) == 0) {
        unsigned *dw = (unsigned *)d;
        const unsigned *sw = (const unsigned *)s;
        while (n >= 4) { *dw++ = *sw++; n -= 4; }
        d = (char *)dw;
        s = (const char *)sw;
    }
    while (n) { *d++ = *s++; n--; }
    return dst;
}

void *memmove(void *dst, const void *src, size_t n)
{
    char *d = dst;
    const char *s = src;
    if (d < s) {                       /* pointer compare: unsigned, exact (s5.2) */
        while (n) { *d++ = *s++; n--; }
    } else {
        while (n) { n--; d[n] = s[n]; }  /* backward: overlap-safe when d > s */
    }
    return dst;
}

void *memset(void *dst, int c, size_t n)
{
    char *d = dst;
    while (n) { *d++ = (char)c; n--; }
    return dst;
}

/* ---- str* ---- */

size_t strlen(const char *s)
{
    const char *p = s;
    while (*p) p++;
    return (size_t)(p - s);
}

int strcmp(const char *a, const char *b)
{
    /* char is unsigned on this target (ABI §1) — which is exactly C's rule for
       strcmp (compare as unsigned char), so the plain difference is correct */
    while (*a && *a == *b) { a++; b++; }
    return (int)*a - (int)*b;
}

int strncmp(const char *a, const char *b, size_t n)
{
    while (n && *a && *a == *b) { a++; b++; n--; }
    if (n == 0) return 0;
    return (int)*a - (int)*b;
}

static int lowerc(int c)
{
    if (c >= 'A' && c <= 'Z') return c + 32;
    return c;
}

int strcasecmp(const char *a, const char *b)
{
    while (*a && lowerc(*a) == lowerc(*b)) { a++; b++; }
    return lowerc(*a) - lowerc(*b);
}

int strncasecmp(const char *a, const char *b, size_t n)
{
    while (n && *a && lowerc(*a) == lowerc(*b)) { a++; b++; n--; }
    if (n == 0) return 0;
    return lowerc(*a) - lowerc(*b);
}

char *strchr(const char *s, int c)
{
    char ch = (char)c;
    while (*s) {
        if (*s == ch) return (char *)s;
        s++;
    }
    if (ch == 0) return (char *)s;     /* the NUL is findable, per spec */
    return 0;
}

char *strrchr(const char *s, int c)
{
    const char *last = 0;
    char ch = (char)c;
    while (*s) {
        if (*s == ch) last = s;
        s++;
    }
    if (ch == 0) return (char *)s;
    return (char *)last;
}

char *strstr(const char *h, const char *n)
{
    if (!*n) return (char *)h;         /* empty needle matches at the start */
    while (*h) {
        const char *a = h;
        const char *b = n;
        while (*a && *b && *a == *b) { a++; b++; }
        if (!*b) return (char *)h;
        h++;
    }
    return 0;
}

char *strncpy(char *dst, const char *src, size_t n)
{
    char *d = dst;
    while (n && *src) { *d++ = *src++; n--; }
    while (n) { *d++ = 0; n--; }       /* spec: pad the remainder with NULs */
    return dst;
}

/* ---- ctype-ish / conversions ---- */

int toupper(int c)
{
    if (c >= 'a' && c <= 'z') return c - 32;
    return c;
}

int abs(int x)
{
    if (x < 0) return -x;
    return x;
}

int atoi(const char *s)
{
    int r = 0;
    int neg = 0;
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\v' || *s == '\f'
           || *s == '\r')
        s++;
    if (*s == '-') { neg = 1; s++; }
    else if (*s == '+') s++;
    while (*s >= '0' && *s <= '9') { r = r * 10 + (*s - '0'); s++; }
    if (neg) return -r;
    return r;
}

/* the byte-swap builtins (i_swap.h's SwapBE path): defined as ordinary functions —
   CIL kept the calls symbolic, our linker resolves them by name like any other. The
   signatures match CIL's own builtin registrations exactly (short/int — probed, not
   guessed); the math runs unsigned internally so the shifts are logical. */
short __builtin_bswap16(short v)
{
    unsigned int u = (unsigned short)v;
    return (short)(((u & 0xFF) << 8) | ((u >> 8) & 0xFF));
}

int __builtin_bswap32(int v)
{
    unsigned int u = (unsigned int)v;
    return (int)((u << 24) | ((u & 0xFF00) << 8) | ((u >> 8) & 0xFF00) | (u >> 24));
}

/* ---- the one-big-block malloc ---- */

extern char *__heap_base;              /* the environment owns the bounds */
extern char *__heap_end;

static char *__heap_ptr = 0;

void *malloc(size_t n)
{
    char *p;
    if (!__heap_ptr) __heap_ptr = __heap_base;
    n = (n + 7) & ~7u;                 /* 8-byte granules, glibc-compatible alignment */
    if (n == 0) n = 8;
    p = __heap_ptr;
    if (n > (size_t)(__heap_end - p)) return 0;
    __heap_ptr = p + n;
    return p;
}

void free(void *p)
{
    (void)p;                           /* bump arena: DOOM's zone does the real reuse */
}

void *calloc(size_t n, size_t size)
{
    size_t total = n * size;
    void *p = malloc(total);
    if (p) memset(p, 0, total);
    return p;
}

void *realloc(void *old, size_t n)
{
    void *p = malloc(n);
    /* the old size is unrecorded, so copy n: may over-read past the old block, but
       stays inside the arena (the new block was carved beyond it) — the caller only
       relies on min(old, new) bytes anyway */
    if (p && old) memcpy(p, old, n);
    return p;
}

char *strdup(const char *s)
{
    size_t n = strlen(s) + 1;
    char *p = malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

/* ---- the glibc ctype/errno seam (host-header artifacts) ----
 *
 * The host-preprocessed .i files expand isspace()/isdigit() & co. into
 * (*__ctype_b_loc())[c] & _ISxxx — glibc's classification-table protocol — and
 * errno into *__errno_location(). The table is 384 unsigned shorts indexed from
 * -128 (so isspace(EOF) is legal; the negative side and 128..255 read 0 in the
 * C locale), built lazily from ASCII range checks to the _ISbit() flag layout
 * the .i enums carry (_ISupper 0x100 ... _ISgraph 0x8000; low byte _ISblank
 * 0x01, _IScntrl 0x02, _ISpunct 0x04, _ISalnum 0x08). The jig diffs the whole
 * flag word against the genuine glibc table, so it cannot drift.
 *
 * errno: one int, never set by this libc — the tree's one live read is
 * M_FileExists's errno == EISDIR probe after a failed fopen, and 0 correctly
 * answers "not a directory". */

static unsigned short __ctype_tab[384];
static const unsigned short *__ctype_tab_ptr;

const unsigned short **__ctype_b_loc(void)
{
    if (!__ctype_tab_ptr) {
        int c;
        for (c = 0; c < 256; c++) {
            unsigned short f = 0;
            if (c >= 'A' && c <= 'Z') f |= 0x100;             /* _ISupper */
            if (c >= 'a' && c <= 'z') f |= 0x200;             /* _ISlower */
            if (f) f |= 0x400 | 0x08;                         /* _ISalpha, _ISalnum */
            if (c >= '0' && c <= '9') f |= 0x800 | 0x08;      /* _ISdigit, _ISalnum */
            if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
                || (c >= 'A' && c <= 'F'))
                f |= 0x1000;                                  /* _ISxdigit */
            if (c == ' ' || (c >= 9 && c <= 13)) f |= 0x2000; /* _ISspace */
            if (c >= 32 && c < 127) f |= 0x4000;              /* _ISprint */
            if (c > 32 && c < 127) f |= 0x8000;               /* _ISgraph */
            if (c == ' ' || c == 9) f |= 0x01;                /* _ISblank */
            if (c < 32 || c == 127) f |= 0x02;                /* _IScntrl */
            if ((f & 0x8000) && !(f & 0x08)) f |= 0x04;       /* _ISpunct */
            __ctype_tab[128 + c] = f;
        }
        __ctype_tab_ptr = __ctype_tab + 128;
    }
    return &__ctype_tab_ptr;
}

static int __errno_storage;

int *__errno_location(void)
{
    return &__errno_storage;
}

/* ---- the printf core: vsnprintf/snprintf (varargs slice) ----
 *
 * va_list is CIL's __builtin_va_list — one pointer into the caller's home area, where
 * our marshaller leaves every argument in memory (ABI §3's "varargs for free"). The
 * emitters share bounded-buffer state through a pointed-to struct: passing buf/cap/pos
 * separately would push helpers past the naive allocator's 6 register homes.
 *
 * Subset (everything DOOM's format strings use): flags '-' '0' · width · precision for
 * %s · l/h length modifiers consumed as no-ops (long = int under ILP32) · conversions
 * d i u x X c s p %%. Unknown conversions print as "%<c>" — visible, never silent.
 * glibc-compatible corners on purpose (the jig diffs against the real thing): %s of
 * NULL prints "(null)"; snprintf returns the WOULD-BE length and always NUL-terminates
 * a nonempty buffer. */

typedef __builtin_va_list va_list;

typedef struct sn_state {
    char *buf;
    size_t cap;
    size_t pos;
} sn_t;

static void sn_chr(sn_t *st, int ch)
{
    if (st->cap && st->pos < st->cap - 1) st->buf[st->pos] = (char)ch;
    st->pos++;
}

static void sn_str(sn_t *st, const char *s, int prec, int width, int left)
{
    int len = 0;
    int k = 0;
    if (!s) s = "(null)";
    while (s[len] && (prec < 0 || len < prec)) len++;
    if (!left) while (width > len) { sn_chr(st, ' '); width--; }
    while (k < len) { sn_chr(st, s[k]); k++; }
    while (width > len) { sn_chr(st, ' '); width--; }
    /* the pad-after loop no-ops when right-aligned: the pad-before consumed width */
}

/* flags bits: 1 = negative (emit '-'), 2 = zero-pad, 4 = left-align, 8 = uppercase.
 * prec >= 0 is the C99 integer precision: minimum digit count (zero-extended),
 * and it defeats the '0' flag; %.0d of 0 prints no digits (glibc-exact). The
 * digit buffer caps the effective precision at 11 — past any 32-bit value, and
 * DOOM's only precision use is the STCFN%.3d font names (HU_Init, found at 1d
 * bring-up: unpadded "STCFN33" missed the lump). */
static void sn_num(sn_t *st, unsigned v, unsigned base, int flags, int width, int prec)
{
    char d[12];
    int len = 0;
    const char *digs = (flags & 8) ? "0123456789ABCDEF" : "0123456789abcdef";
    int total;
    if (prec >= 0) flags &= ~2;
    if (v == 0 && prec != 0) d[len++] = '0';
    while (v) { d[len++] = digs[v % base]; v = v / base; }
    while (len < prec && len < 11) d[len++] = '0';
    total = len + ((flags & 1) ? 1 : 0);
    /* C99 padding order: spaces before the sign, zeros after it; '-' wins over '0' */
    if (!(flags & 4) && !(flags & 2))
        while (width > total) { sn_chr(st, ' '); width--; }
    if (flags & 1) sn_chr(st, '-');
    if (!(flags & 4) && (flags & 2))
        while (width > total) { sn_chr(st, '0'); width--; }
    while (len > 0) { len--; sn_chr(st, d[len]); }
    while (width > total) { sn_chr(st, ' '); width--; }
}

int vsnprintf(char *buf, size_t n, const char *fmt, va_list ap)
{
    sn_t st;
    st.buf = buf;
    st.cap = n;
    st.pos = 0;
    while (*fmt) {
        char c = *fmt++;
        int flags = 0;
        int width = 0;
        int prec = -1;
        if (c != '%') { sn_chr(&st, c); continue; }
        for (;;) {
            if (*fmt == '-') { flags |= 4; fmt++; }
            else if (*fmt == '0') { flags |= 2; fmt++; }
            else break;
        }
        while (*fmt >= '0' && *fmt <= '9') { width = width * 10 + (*fmt - '0'); fmt++; }
        if (*fmt == '.') {
            fmt++;
            prec = 0;
            while (*fmt >= '0' && *fmt <= '9') { prec = prec * 10 + (*fmt - '0'); fmt++; }
        }
        while (*fmt == 'l' || *fmt == 'h') fmt++;   /* no-ops under ILP32 */
        c = *fmt++;
        if (c == 0) break;                          /* trailing '%': stop quietly */
        if (c == 'd' || c == 'i') {
            int v = __builtin_va_arg(ap, int);
            unsigned u = (unsigned)v;
            int fl = flags;
            if (v < 0) { fl |= 1; u = 0u - u; }     /* INT_MIN-safe magnitude */
            sn_num(&st, u, 10, fl, width, prec);
        } else if (c == 'u') {
            sn_num(&st, __builtin_va_arg(ap, unsigned), 10, flags, width, prec);
        } else if (c == 'x') {
            sn_num(&st, __builtin_va_arg(ap, unsigned), 16, flags, width, prec);
        } else if (c == 'X') {
            sn_num(&st, __builtin_va_arg(ap, unsigned), 16, flags | 8, width, prec);
        } else if (c == 'p') {
            sn_chr(&st, '0');
            sn_chr(&st, 'x');
            sn_num(&st, __builtin_va_arg(ap, unsigned), 16, flags, 0, -1);
        } else if (c == 'c') {
            if (!(flags & 4)) while (width > 1) { sn_chr(&st, ' '); width--; }
            sn_chr(&st, __builtin_va_arg(ap, int));
            while (width > 1) { sn_chr(&st, ' '); width--; }
        } else if (c == 's') {
            sn_str(&st, __builtin_va_arg(ap, const char *), prec, width, flags & 4);
        } else if (c == '%') {
            sn_chr(&st, '%');
        } else {
            sn_chr(&st, '%');                       /* unknown: visible, never silent */
            sn_chr(&st, c);
        }
    }
    if (n) {
        size_t t = st.pos;
        if (t > n - 1) t = n - 1;
        buf[t] = 0;
    }
    return (int)st.pos;
}

int snprintf(char *buf, size_t n, const char *fmt, ...)
{
    va_list ap;
    int r;
    __builtin_va_start(ap, fmt);
    r = vsnprintf(buf, n, fmt, ap);
    __builtin_va_end(ap);
    return r;
}
