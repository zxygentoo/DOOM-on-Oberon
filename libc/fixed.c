/* fixed.c — the m_fixed.c replacement (AGENT.md §4's second real trap).
 *
 * doomgeneric's m_fixed.c is int64_t code — and the host-preprocessed .i files spell
 * int64_t as `long` (x86-64 stdint.h), which our ILP32 machdep legitimately sizes at
 * 32 bits: the tree's FixedMul compiled SILENTLY WRONG (the census caught it in the
 * disassembly — MUL's high word, sitting right there in H, never read). So m_fixed is
 * replaced wholesale, exactly as planned: doomcc skips m_fixed.i, FixedMul expands as
 * the ABI §5 linker intrinsic (MUL + MOV' from H + repack, 6 instructions), and
 * FixedDiv lives here in C that never touches a 64-bit value.
 *
 * FixedDiv = (a<<16)/b with a 48-bit dividend the 32/32 divider can't take: one
 * hardware division gives the integer part and its remainder, then 16 restoring steps
 * produce the fraction bits — ~200 cycles, inside the plan's 200-300 estimate. The
 * overflow guard is doomgeneric's own (saturate when |a|>>14 >= |b|), and it bounds
 * the quotient below 2^30, so the 16 shifts can't overflow. All magnitudes run
 * unsigned (0u - x negates INT_MIN safely); C's truncation = floor on magnitudes,
 * sign applied last — matching the int64_t original bit for bit. */

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
