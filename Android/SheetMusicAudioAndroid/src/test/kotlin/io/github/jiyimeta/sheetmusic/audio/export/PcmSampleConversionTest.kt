package io.github.jiyimeta.sheetmusic.audio.export

import org.junit.Assert.assertEquals
import org.junit.Test

class PcmSampleConversionTest {
    @Test fun floatToInt16InterleavesStereo() {
        val left = floatArrayOf(0f, 0.5f, -0.5f)
        val right = floatArrayOf(0f, -0.5f, 0.5f)
        val out = ShortArray(6)
        PcmSampleConversion.floatToInt16Interleaved(left, right, frames = 3, mono = false, out = out)
        assertEquals(0, out[0].toInt())
        assertEquals(0, out[1].toInt())
        assertEquals(16383, out[2].toInt())  // 0.5 * 32767 ≈ 16383 after .toInt()
        assertEquals(-16383, out[3].toInt())
        assertEquals(-16383, out[4].toInt())
        assertEquals(16383, out[5].toInt())
    }

    @Test fun floatToInt16ClipsAtBoundaries() {
        // Stereo interleaved order is [L0, R0, L1, R1]. Pick L=[+2,-2] and R=[-2,+2]
        // so each of the four output slots exercises a distinct boundary clip.
        val left = floatArrayOf(2.0f, -2.0f)
        val right = floatArrayOf(-2.0f, 2.0f)
        val out = ShortArray(4)
        PcmSampleConversion.floatToInt16Interleaved(left, right, frames = 2, mono = false, out = out)
        assertEquals(32767, out[0].toInt())
        assertEquals(-32768, out[1].toInt())
        assertEquals(-32768, out[2].toInt())
        assertEquals(32767, out[3].toInt())
    }

    @Test fun floatToInt16MonoDropsRightChannel() {
        val left = floatArrayOf(0.5f, -0.5f)
        val right = floatArrayOf(0.25f, -0.25f)
        val out = ShortArray(2)
        PcmSampleConversion.floatToInt16Interleaved(left, right, frames = 2, mono = true, out = out)
        assertEquals(16383, out[0].toInt())
        assertEquals(-16383, out[1].toInt())
    }

    @Test fun floatToInt24LEEncodesThreeBytesLittleEndian() {
        val left = floatArrayOf(0.5f)
        val right = floatArrayOf(0f)
        val out = ByteArray(6)
        PcmSampleConversion.floatToInt24LE(left, right, frames = 1, mono = false, out = out)
        // 0.5 * 8388607 = 4194303 → 0x3FFFFF → LE bytes [0xFF, 0xFF, 0x3F]
        assertEquals(0xFF, out[0].toInt() and 0xFF)
        assertEquals(0xFF, out[1].toInt() and 0xFF)
        assertEquals(0x3F, out[2].toInt() and 0xFF)
    }

    @Test fun floatToInt24BEEncodesThreeBytesBigEndian() {
        val left = floatArrayOf(0.5f)
        val right = floatArrayOf(0f)
        val out = ByteArray(6)
        PcmSampleConversion.floatToInt24BE(left, right, frames = 1, mono = false, out = out)
        // 0.5 * 8388607 = 4194303 → 0x3FFFFF → BE bytes [0x3F, 0xFF, 0xFF]
        assertEquals(0x3F, out[0].toInt() and 0xFF)
        assertEquals(0xFF, out[1].toInt() and 0xFF)
        assertEquals(0xFF, out[2].toInt() and 0xFF)
    }

    @Test fun floatToFloat32LERoundTrips() {
        val left = floatArrayOf(0.5f, 0.25f)
        val right = floatArrayOf(-0.5f, -0.25f)
        val out = ByteArray(16)
        PcmSampleConversion.floatToFloat32LE(left, right, frames = 2, mono = false, out = out)
        val bb = java.nio.ByteBuffer.wrap(out).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        assertEquals(0.5f, bb.getFloat(0), 0.0f)
        assertEquals(-0.5f, bb.getFloat(4), 0.0f)
        assertEquals(0.25f, bb.getFloat(8), 0.0f)
        assertEquals(-0.25f, bb.getFloat(12), 0.0f)
    }
}
