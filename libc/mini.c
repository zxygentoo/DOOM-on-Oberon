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
