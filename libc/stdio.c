/* stdio.c — the memory-backed stdio + console (1c.3).
 *
 * The blob never touches storage (AGENT.md §2.7): every readable "file" is a byte
 * range in himem that the port layer registers by name (__file_register — the stub
 * loads the WAD, Init registers it; doomgeneric's w_file_stdc then fopen/freads it
 * none the wiser). Writes are v1 no-ops per the §5 boundary contract: fopen for
 * writing returns NULL, and M_LoadDefaults & co already tolerate the missing files.
 *
 * The tree's .i files carry glibc's COMPLETE struct _IO_FILE (32 fields), so FILE
 * stays an incomplete type here and the real cursor lives in a private struct, cast at
 * the public boundary — callers treat FILE* as opaque, which is stdio's own contract.
 * Type spellings (size_t = unsigned long, long offsets) mirror the .i prototypes
 * exactly: Mergecil is nominal about types (the 1c.1 lesson, twice now).
 *
 * The console (printf/puts/putchar, and fprintf to stdout/stderr) formats through
 * mini.c's vsnprintf and drains to the RS232 UART, Oberon-style: wait on status bit 1
 * (tx ready) at 0xFFFFFFCC, write data at 0xFFFFFFC8 — the sign-extended MMIO
 * addresses both the emulator and the 24-bit bus agree on. NOTE: with no serial
 * attached (the bare jig emulator) the status never reads ready, so jig samples must
 * not call the console functions; the 1d harness attaches a serial. */

typedef unsigned long size_t;
typedef unsigned int __mode_t;
typedef __builtin_va_list va_list;

extern int strcmp(const char *a, const char *b);
extern void *memcpy(void *dst, const void *src, size_t n);
extern int vsnprintf(char *buf, size_t n, const char *fmt, va_list ap);

/* FILE stays incomplete (the tree owns glibc's real one); ours is __mfile_t inside */
typedef struct _IO_FILE FILE;

typedef struct __mfile {
    const char *base;
    size_t size;
    size_t pos;
    int in_use;
} __mfile_t;

/* the console sentinel: fprintf(stderr, ...) and fprintf(stdout, ...) drain to UART */
static __mfile_t __console;
FILE *stdin = 0;
FILE *stdout = (FILE *)&__console;
FILE *stderr = (FILE *)&__console;

/* ---- the registry: name -> himem range, filled by the port layer at Init ---- */

typedef struct __mreg {
    const char *name;
    const char *base;
    size_t size;
} __mreg_t;

static __mreg_t __files[4];

void __file_register(const char *name, const void *base, size_t size)
{
    int k;
    for (k = 0; k < 4; k++) {
        if (!__files[k].name) {
            __files[k].name = name;
            __files[k].base = base;
            __files[k].size = size;
            return;
        }
    }
}

/* ---- the fopen family ---- */

static __mfile_t __handles[4];

FILE *fopen(const char *name, const char *mode)
{
    int k;
    if (!mode || mode[0] == 'w' || mode[0] == 'a') return 0;   /* writes: v1 no-op */
    for (k = 0; k < 4; k++) {
        if (__files[k].name && strcmp(__files[k].name, name) == 0) {
            int h;
            for (h = 0; h < 4; h++) {
                if (!__handles[h].in_use) {
                    __handles[h].base = __files[k].base;
                    __handles[h].size = __files[k].size;
                    __handles[h].pos = 0;
                    __handles[h].in_use = 1;
                    return (FILE *)&__handles[h];
                }
            }
            return 0;
        }
    }
    return 0;
}

int fclose(FILE *f)
{
    __mfile_t *m = (__mfile_t *)f;
    if (m && m != &__console) m->in_use = 0;
    return 0;
}

size_t fread(void *ptr, size_t size, size_t n, FILE *f)
{
    __mfile_t *m = (__mfile_t *)f;
    size_t want;
    size_t avail;
    if (!m || m == &__console || size == 0) return 0;
    want = size * n;
    avail = m->size - m->pos;
    if (want > avail) want = avail;
    memcpy(ptr, m->base + m->pos, want);
    m->pos += want;
    return want / size;                /* glibc: FULL items read */
}

int fseek(FILE *f, long off, int whence)
{
    __mfile_t *m = (__mfile_t *)f;
    long p;
    if (!m || m == &__console) return -1;
    if (whence == 0) p = off;                       /* SEEK_SET */
    else if (whence == 1) p = (long)m->pos + off;   /* SEEK_CUR */
    else p = (long)m->size + off;                   /* SEEK_END */
    if (p < 0 || (size_t)p > m->size) return -1;
    m->pos = (size_t)p;
    return 0;
}

long ftell(FILE *f)
{
    __mfile_t *m = (__mfile_t *)f;
    if (!m || m == &__console) return -1;
    return (long)m->pos;
}

/* ---- the console: format through vsnprintf, drain to the UART ---- */

static void __uart_putc(int c)
{
    while (!(*(volatile unsigned *)0xFFFFFFCC & 2)) { }   /* tx ready (RS232 status) */
    *(volatile unsigned *)0xFFFFFFC8 = (unsigned)c;
}

int putchar(int c)
{
    __uart_putc(c);
    return c;
}

int puts(const char *s)
{
    while (*s) __uart_putc(*s++);
    __uart_putc('\n');
    return 0;
}

/* one line at a time; longer output truncates — a v1 debug console, not a stream */
static int __console_emit(const char *fmt, va_list ap)
{
    char buf[256];
    int r = vsnprintf(buf, 256, fmt, ap);
    int k = 0;
    while (buf[k]) __uart_putc(buf[k++]);
    return r;
}

int printf(const char *fmt, ...)
{
    va_list ap;
    int r;
    __builtin_va_start(ap, fmt);
    r = __console_emit(fmt, ap);
    __builtin_va_end(ap);
    return r;
}

int fprintf(FILE *f, const char *fmt, ...)
{
    va_list ap;
    int r;
    if ((__mfile_t *)f != &__console) return 0;   /* only the console writes in v1 */
    __builtin_va_start(ap, fmt);
    r = __console_emit(fmt, ap);
    __builtin_va_end(ap);
    return r;
}

int vfprintf(FILE *f, const char *fmt, va_list ap)
{
    if ((__mfile_t *)f != &__console) return 0;
    return __console_emit(fmt, ap);
}

int fflush(FILE *f)
{
    (void)f;                           /* the UART sink is unbuffered */
    return 0;
}

size_t fwrite(const void *ptr, size_t size, size_t n, FILE *f)
{
    const char *s = ptr;
    size_t total = size * n;
    size_t k;
    if ((__mfile_t *)f != &__console) return 0;   /* memory files are read-only */
    for (k = 0; k < total; k++) __uart_putc(s[k]);
    return n;
}

/* ---- the polite refusals: no filesystem exists behind these ---- */

int remove(const char *path)
{
    (void)path;
    return -1;
}

int rename(const char *a, const char *b)
{
    (void)a;
    (void)b;
    return -1;
}

int mkdir(const char *path, __mode_t mode)
{
    (void)path;
    (void)mode;
    return 0;                          /* pretend: the later fopen("w") says no anyway */
}

int system(const char *cmd)
{
    (void)cmd;
    return -1;
}

/* v1: no config file ever loads (fopen("...cfg") misses the registry), so sscanf has
   no live callers; a zero-conversions stub keeps the link honest without pretending
   to parse. Revisit if a registered file ever feeds it. */
int sscanf(const char *s, const char *fmt, ...)
{
    (void)s;
    (void)fmt;
    return 0;
}
