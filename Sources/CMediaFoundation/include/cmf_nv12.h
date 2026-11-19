// BGRA to NV12 for the MP4 writer (cmediafoundation.c), apart from Media Foundation so it is plain C with no Windows
// header: the converter every video frame goes through, and the reference it must match bit for bit.
#ifndef CMF_NV12_H
#define CMF_NV12_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A YUV matrix's studio-range coefficients in 1/256ths: luma from R, G, B, then Cb's and Cr's. Luma's sum to 220 and
/// each chroma's to 0, and no chroma coefficient exceeds 112 in size — the bounds the SIMD path relies on to keep its
/// sums in 16 bits.
typedef struct {
    int yr, yg, yb, ur, ug, ub, vr, vg, vb;
} cmf_nv12_coefficients;

/// BGRA (premultiplied, opaque in a score video) to NV12 in `m`, studio range — luma per pixel, chroma from each 2x2
/// block's average. Rows top-down in both; `width` and `height` even. One pass over the frame, eight pixels of two rows
/// at a time with SSE2 where the compiler targets it, the columns past the last eight by the scalar formula; the output
/// is `cmf_bgra_to_nv12_reference`'s, byte for byte.
void cmf_bgra_to_nv12(const uint8_t *bgra, uint8_t *nv12, uint32_t width, uint32_t height,
                      const cmf_nv12_coefficients *m);

/// The conversion as it was first written — two plain passes, luma then chroma — kept as the definition of the output:
/// the tests hold `cmf_bgra_to_nv12` to it.
void cmf_bgra_to_nv12_reference(const uint8_t *bgra, uint8_t *nv12, uint32_t width, uint32_t height,
                                const cmf_nv12_coefficients *m);

#ifdef __cplusplus
}
#endif

#endif
