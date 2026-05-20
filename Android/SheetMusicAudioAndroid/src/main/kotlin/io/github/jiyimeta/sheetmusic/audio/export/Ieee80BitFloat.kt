package io.github.jiyimeta.sheetmusic.audio.export

/**
 * Encodes IEEE 754 extended-precision 80-bit (big-endian) floats, as used
 * by the AIFF / AIFC `COMM` chunk's sample-rate field.
 *
 * Layout:
 *   - 1 sign bit (always 0 here — sample rates are positive)
 *   - 15-bit biased exponent (bias = 16383)
 *   - 64-bit mantissa with the leading 1 *explicit* (unlike IEEE 754
 *     binary64, which hides the integer bit). For a normalized value
 *     in `[1.0, 2.0)`, the MSB of the mantissa is set.
 */
internal object Ieee80BitFloat {
    /** Encode [value] as a big-endian 80-bit IEEE 754 extended-precision float. */
    fun encode(value: Double): ByteArray {
        require(value > 0) { "AIFF sample rate must be positive" }
        val out = ByteArray(10)
        var m = value
        var exp = 0
        while (m < 1.0) { m *= 2.0; exp-- }
        while (m >= 2.0) { m /= 2.0; exp++ }
        val biasedExp = exp + 16383
        // Sign bit (0) + 15-bit biased exponent.
        out[0] = ((biasedExp shr 8) and 0x7F).toByte()
        out[1] = (biasedExp and 0xFF).toByte()
        // 64-bit mantissa, MSB set (since m is normalized to [1.0, 2.0)).
        // Compute as: leading 1 bit (set explicitly) | lower 63 bits from fractional part.
        // We cannot do `(m * 2^63).toLong()` directly because m ≥ 1.0 → product ≥ 2^63,
        // which overflows the signed Long range. Also, `(1L shl 63).toDouble()` is
        // negative (it's Long.MIN_VALUE) — write 2^63 as a positive Double literal.
        val twoTo63 = 9223372036854775808.0
        val fractional = m - 1.0
        val lower63 = (fractional * twoTo63).toLong()
        val mantissa = (1L shl 63) or (lower63 and Long.MAX_VALUE)
        for (i in 0 until 8) {
            out[2 + i] = ((mantissa ushr ((7 - i) * 8)) and 0xFFL).toByte()
        }
        return out
    }
}
