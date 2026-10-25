/* fixed.c — FixedDiv, replacing doomgeneric's m_fixed.c.
 *
 * m_fixed.c is int64_t code, and the host-preprocessed .i files spell int64_t as
 * `long` (x86-64 stdint.h), which our ILP32 target sizes at 32 bits: it would
 * compile silently wrong. So doomcc skips m_fixed.i, FixedMul expands as the ABI §5
 * linker intrinsic (MUL, then MOV' of the high word from H, then a repack: 6
 * instructions), and FixedDiv lives here, in C that never touches a 64-bit value.
 *
 * FixedDiv = (a<<16)/b, a 48-bit dividend the 32/32 divider can't take: one hardware
 * division gives the integer part and its remainder, then 16 restoring steps
 * produce the fraction bits (~200 cycles). The overflow guard is doomgeneric's own
 * (saturate when |a|>>14 >= |b|), and it bounds the quotient below 2^30, so the 16
 * shifts can't overflow. Magnitudes run unsigned (0u - x negates INT_MIN safely);
 * truncation = floor on magnitudes, sign applied last — bit for bit the int64_t
 * original. */

typedef int fixed_t;

extern int abs(int x);

fixed_t FixedDiv(fixed_t a, fixed_t b)
{
    if ((abs(a) >> 14) >= abs(b))
        return (a ^ b) < 0 ? (fixed_t)0x80000000 : (fixed_t)0x7FFFFFFF;
    {
        int neg = (a ^ b) < 0;
        unsigned ua = a < 0 ? 0u - (unsigned)a : (unsigned)a;
        unsigned ub = b < 0 ? 0u - (unsigned)b : (unsigned)b;
        unsigned q = ua / ub;          /* integer part: < 2^14 by the guard */
        unsigned r = ua % ub;
        int k;
        for (k = 0; k < 16; k++) {     /* the fraction: restoring long division */
            r <<= 1;
            q <<= 1;
            if (r >= ub) {
                r -= ub;
                q += 1;
            }
        }
        return neg ? (fixed_t)(0u - q) : (fixed_t)q;
    }
}
