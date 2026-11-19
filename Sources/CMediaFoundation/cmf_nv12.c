// BGRA to NV12 (cmf_nv12.h). The reference is the writer's first converter, unchanged; `cmf_bgra_to_nv12` reads the
// frame once, two rows at a time, and does eight pixels per step with SSE2 (every x64 CPU has it), giving the same
// bytes: luma's terms are all positive and sum below 220 * 255 + 128 < 65536, so they add exactly in unsigned 16-bit
// lanes; each chroma term is at most 112 * 255 = 28560 in size and their sum stays inside that, so they add exactly in
// signed 16-bit lanes; and the shifts are the reference's (logical for luma, arithmetic for chroma).
#include "cmf_nv12.h"

#include <stddef.h>

#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#include <emmintrin.h>
#define CMF_NV12_SSE2 1
#endif

void cmf_bgra_to_nv12_reference(const uint8_t *bgra, uint8_t *nv12, uint32_t width, uint32_t height,
                                const cmf_nv12_coefficients *m) {
    uint8_t *luma = nv12;
    uint8_t *chroma = nv12 + (size_t)width * height;
    for (uint32_t y = 0; y < height; y++) {
        const uint8_t *row = bgra + (size_t)y * width * 4;
        uint8_t *out = luma + (size_t)y * width;
        for (uint32_t x = 0; x < width; x++) {
            int b = row[x * 4], g = row[x * 4 + 1], r = row[x * 4 + 2];
            out[x] = (uint8_t)(((m->yr * r + m->yg * g + m->yb * b + 128) >> 8) + 16);
        }
    }
    for (uint32_t y = 0; y < height; y += 2) {
        const uint8_t *top = bgra + (size_t)y * width * 4;
        const uint8_t *bottom = top + (size_t)width * 4;
        uint8_t *out = chroma + (size_t)(y / 2) * width;
        for (uint32_t x = 0; x < width; x += 2) {
            const uint8_t *p = top + x * 4;
            const uint8_t *q = bottom + x * 4;
            int b = (p[0] + p[4] + q[0] + q[4] + 2) >> 2;
            int g = (p[1] + p[5] + q[1] + q[5] + 2) >> 2;
            int r = (p[2] + p[6] + q[2] + q[6] + 2) >> 2;
            out[x] = (uint8_t)(((m->ur * r + m->ug * g + m->ub * b + 128) >> 8) + 128);
            out[x + 1] = (uint8_t)(((m->vr * r + m->vg * g + m->vb * b + 128) >> 8) + 128);
        }
    }
}

/// The scalar formula for the 2x2 block at column `x` of rows `top` / `bottom`: its four luma bytes and its Cb, Cr.
static void block_scalar(const uint8_t *top, const uint8_t *bottom, uint8_t *luma_top, uint8_t *luma_bottom,
                         uint8_t *chroma, uint32_t x, const cmf_nv12_coefficients *m) {
    const uint8_t *p = top + x * 4;
    const uint8_t *q = bottom + x * 4;
    luma_top[x] = (uint8_t)(((m->yr * p[2] + m->yg * p[1] + m->yb * p[0] + 128) >> 8) + 16);
    luma_top[x + 1] = (uint8_t)(((m->yr * p[6] + m->yg * p[5] + m->yb * p[4] + 128) >> 8) + 16);
    luma_bottom[x] = (uint8_t)(((m->yr * q[2] + m->yg * q[1] + m->yb * q[0] + 128) >> 8) + 16);
    luma_bottom[x + 1] = (uint8_t)(((m->yr * q[6] + m->yg * q[5] + m->yb * q[4] + 128) >> 8) + 16);
    int b = (p[0] + p[4] + q[0] + q[4] + 2) >> 2;
    int g = (p[1] + p[5] + q[1] + q[5] + 2) >> 2;
    int r = (p[2] + p[6] + q[2] + q[6] + 2) >> 2;
    chroma[x] = (uint8_t)(((m->ur * r + m->ug * g + m->ub * b + 128) >> 8) + 128);
    chroma[x + 1] = (uint8_t)(((m->vr * r + m->vg * g + m->vb * b + 128) >> 8) + 128);
}

#ifdef CMF_NV12_SSE2
/// Eight BGRA pixels at `p` as their B, G and R in eight 16-bit lanes each.
static void planes(const uint8_t *p, __m128i *b, __m128i *g, __m128i *r) {
    const __m128i low = _mm_set1_epi32(0xFF);
    __m128i a = _mm_loadu_si128((const __m128i *)p);
    __m128i c = _mm_loadu_si128((const __m128i *)(p + 16));
    *b = _mm_packs_epi32(_mm_and_si128(a, low), _mm_and_si128(c, low));
    *g = _mm_packs_epi32(_mm_and_si128(_mm_srli_epi32(a, 8), low), _mm_and_si128(_mm_srli_epi32(c, 8), low));
    *r = _mm_packs_epi32(_mm_and_si128(_mm_srli_epi32(a, 16), low), _mm_and_si128(_mm_srli_epi32(c, 16), low));
}

/// Eight luma bytes in the low half: ((yr*R + yg*G + yb*B + 128) >> 8) + 16, in unsigned 16-bit lanes.
static __m128i luma8(__m128i b, __m128i g, __m128i r, __m128i yr, __m128i yg, __m128i yb) {
    __m128i sum = _mm_add_epi16(_mm_add_epi16(_mm_mullo_epi16(r, yr), _mm_mullo_epi16(g, yg)), _mm_mullo_epi16(b, yb));
    sum = _mm_srli_epi16(_mm_add_epi16(sum, _mm_set1_epi16(128)), 8);
    sum = _mm_add_epi16(sum, _mm_set1_epi16(16));
    return _mm_packus_epi16(sum, sum);
}

/// The 2x2 averages of a channel from its two rows' eight lanes: four values, (sum + 2) >> 2, in the low four lanes.
static __m128i average4(__m128i top, __m128i bottom) {
    __m128i pairs = _mm_madd_epi16(_mm_add_epi16(top, bottom), _mm_set1_epi16(1));
    pairs = _mm_srai_epi32(_mm_add_epi32(pairs, _mm_set1_epi32(2)), 2);
    return _mm_packs_epi32(pairs, pairs);
}

/// Four Cb or Cr values, ((cr*R + cg*G + cb*B + 128) >> 8) + 128, in signed 16-bit lanes.
static __m128i chroma4(__m128i b, __m128i g, __m128i r, __m128i cr, __m128i cg, __m128i cb) {
    __m128i sum = _mm_add_epi16(_mm_add_epi16(_mm_mullo_epi16(r, cr), _mm_mullo_epi16(g, cg)), _mm_mullo_epi16(b, cb));
    sum = _mm_srai_epi16(_mm_add_epi16(sum, _mm_set1_epi16(128)), 8);
    return _mm_add_epi16(sum, _mm_set1_epi16(128));
}
#endif

void cmf_bgra_to_nv12(const uint8_t *bgra, uint8_t *nv12, uint32_t width, uint32_t height,
                      const cmf_nv12_coefficients *m) {
    uint8_t *luma = nv12;
    uint8_t *chroma = nv12 + (size_t)width * height;
#ifdef CMF_NV12_SSE2
    const __m128i yr = _mm_set1_epi16((short)m->yr), yg = _mm_set1_epi16((short)m->yg), yb = _mm_set1_epi16((short)m->yb);
    const __m128i ur = _mm_set1_epi16((short)m->ur), ug = _mm_set1_epi16((short)m->ug), ub = _mm_set1_epi16((short)m->ub);
    const __m128i vr = _mm_set1_epi16((short)m->vr), vg = _mm_set1_epi16((short)m->vg), vb = _mm_set1_epi16((short)m->vb);
    const uint32_t wide = width & ~7u;
#else
    const uint32_t wide = 0;
#endif
    for (uint32_t y = 0; y < height; y += 2) {
        const uint8_t *top = bgra + (size_t)y * width * 4;
        const uint8_t *bottom = top + (size_t)width * 4;
        uint8_t *luma_top = luma + (size_t)y * width;
        uint8_t *luma_bottom = luma_top + width;
        uint8_t *out = chroma + (size_t)(y / 2) * width;
        uint32_t x = 0;
#ifdef CMF_NV12_SSE2
        for (; x < wide; x += 8) {
            __m128i bt, gt, rt, bb, gb, rb;
            planes(top + (size_t)x * 4, &bt, &gt, &rt);
            planes(bottom + (size_t)x * 4, &bb, &gb, &rb);
            _mm_storel_epi64((__m128i *)(luma_top + x), luma8(bt, gt, rt, yr, yg, yb));
            _mm_storel_epi64((__m128i *)(luma_bottom + x), luma8(bb, gb, rb, yr, yg, yb));
            __m128i b = average4(bt, bb), g = average4(gt, gb), r = average4(rt, rb);
            __m128i u = chroma4(b, g, r, ur, ug, ub);
            __m128i v = chroma4(b, g, r, vr, vg, vb);
            __m128i interleaved = _mm_unpacklo_epi8(_mm_packus_epi16(u, u), _mm_packus_epi16(v, v));
            _mm_storel_epi64((__m128i *)(out + x), interleaved);
        }
#endif
        (void)wide;
        for (; x < width; x += 2) {
            block_scalar(top, bottom, luma_top, luma_bottom, out, x, m);
        }
    }
}
