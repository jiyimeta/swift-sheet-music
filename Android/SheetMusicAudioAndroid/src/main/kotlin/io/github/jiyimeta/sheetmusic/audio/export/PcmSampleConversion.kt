package io.github.jiyimeta.sheetmusic.audio.export

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Shared float→int / float→float PCM sample conversion helpers used by all four
 * audio-file encoders (WAV / AIFF / M4A / MP3).
 *
 * All functions consume two `FloatArray`s (left/right channels), a `frames` count,
 * and a `mono` flag (mono drops the right channel). Output is written into a
 * pre-allocated buffer.
 *
 * Clipping is symmetric: `(x * MAX).toInt().coerceIn(MIN, MAX)`. Note that
 * `.toInt()` truncates toward zero, so e.g. `0.5f * 8388607f = 4194303.5 → 4194303`.
 */
internal object PcmSampleConversion {
    private const val INT16_MAX_F = 32767f
    private const val INT16_MIN_I = -32768
    private const val INT16_MAX_I = 32767
    private const val INT24_MAX_F = 8388607f
    private const val INT24_MIN_I = -8388608
    private const val INT24_MAX_I = 8388607
    private const val INT32_MAX_F = 2147483647f

    fun floatToInt16Interleaved(
        left: FloatArray,
        right: FloatArray,
        frames: Int,
        mono: Boolean,
        out: ShortArray,
    ) {
        if (mono) {
            for (i in 0 until frames) out[i] = clipInt16(left[i])
        } else {
            var j = 0
            for (i in 0 until frames) {
                out[j++] = clipInt16(left[i])
                out[j++] = clipInt16(right[i])
            }
        }
    }

    fun floatToInt16InterleavedBE(
        left: FloatArray,
        right: FloatArray,
        frames: Int,
        mono: Boolean,
        out: ByteArray,
    ) {
        val bb = ByteBuffer.wrap(out).order(ByteOrder.BIG_ENDIAN)
        for (i in 0 until frames) {
            bb.putShort(clipInt16(left[i]))
            if (!mono) bb.putShort(clipInt16(right[i]))
        }
    }

    fun floatToInt24LE(
        left: FloatArray,
        right: FloatArray,
        frames: Int,
        mono: Boolean,
        out: ByteArray,
    ) {
        var p = 0
        for (i in 0 until frames) {
            p = writeInt24LE(left[i], out, p)
            if (!mono) p = writeInt24LE(right[i], out, p)
        }
    }

    fun floatToInt24BE(
        left: FloatArray,
        right: FloatArray,
        frames: Int,
        mono: Boolean,
        out: ByteArray,
    ) {
        var p = 0
        for (i in 0 until frames) {
            p = writeInt24BE(left[i], out, p)
            if (!mono) p = writeInt24BE(right[i], out, p)
        }
    }

    fun floatToInt32LE(
        left: FloatArray,
        right: FloatArray,
        frames: Int,
        mono: Boolean,
        out: ByteArray,
    ) {
        val bb = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN)
        for (i in 0 until frames) {
            bb.putInt(clipInt32(left[i]))
            if (!mono) bb.putInt(clipInt32(right[i]))
        }
    }

    fun floatToInt32BE(
        left: FloatArray,
        right: FloatArray,
        frames: Int,
        mono: Boolean,
        out: ByteArray,
    ) {
        val bb = ByteBuffer.wrap(out).order(ByteOrder.BIG_ENDIAN)
        for (i in 0 until frames) {
            bb.putInt(clipInt32(left[i]))
            if (!mono) bb.putInt(clipInt32(right[i]))
        }
    }

    fun floatToFloat32LE(
        left: FloatArray,
        right: FloatArray,
        frames: Int,
        mono: Boolean,
        out: ByteArray,
    ) {
        val bb = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN)
        for (i in 0 until frames) {
            bb.putFloat(left[i])
            if (!mono) bb.putFloat(right[i])
        }
    }

    fun floatToFloat32BE(
        left: FloatArray,
        right: FloatArray,
        frames: Int,
        mono: Boolean,
        out: ByteArray,
    ) {
        val bb = ByteBuffer.wrap(out).order(ByteOrder.BIG_ENDIAN)
        for (i in 0 until frames) {
            bb.putFloat(left[i])
            if (!mono) bb.putFloat(right[i])
        }
    }

    private fun clipInt16(x: Float): Short {
        val v = (x * INT16_MAX_F).toInt().coerceIn(INT16_MIN_I, INT16_MAX_I)
        return v.toShort()
    }

    private fun clipInt24(x: Float): Int =
        (x * INT24_MAX_F).toInt().coerceIn(INT24_MIN_I, INT24_MAX_I)

    private fun clipInt32(x: Float): Int {
        val v = (x.toDouble() * INT32_MAX_F).toLong()
            .coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong())
        return v.toInt()
    }

    private fun writeInt24LE(x: Float, out: ByteArray, offset: Int): Int {
        val v = clipInt24(x)
        out[offset] = (v and 0xFF).toByte()
        out[offset + 1] = ((v ushr 8) and 0xFF).toByte()
        out[offset + 2] = ((v ushr 16) and 0xFF).toByte()
        return offset + 3
    }

    private fun writeInt24BE(x: Float, out: ByteArray, offset: Int): Int {
        val v = clipInt24(x)
        out[offset] = ((v ushr 16) and 0xFF).toByte()
        out[offset + 1] = ((v ushr 8) and 0xFF).toByte()
        out[offset + 2] = (v and 0xFF).toByte()
        return offset + 3
    }
}
