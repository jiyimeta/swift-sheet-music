package io.github.jiyimeta.sheetmusic.audio.recording

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class PcmConversionTest {
    @Test fun `float samples round and clamp to plus or minus 32767, as Apple's cache does`() {
        val out = PcmConversion.int16(floatArrayOf(0f, 0.5f, -0.5f, 1f, -1f, 2f, -2f))
        assertArrayEquals(shortArrayOf(0, 16384, -16384, 32767, -32767, 32767, -32767), out)
    }

    @Test fun `mono and stereo pass through, more channels keep the front two`() {
        val mono = shortArrayOf(1, 2, 3)
        val (same, channels) = PcmConversion.atMostStereo(mono, 3, 1, ShortArray(0))
        assertSame(mono, same)
        assertEquals(1, channels)

        val surround = shortArrayOf(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) // two frames of six channels
        val (stereo, two) = PcmConversion.atMostStereo(surround, 2, 6, ShortArray(0))
        assertEquals(2, two)
        assertArrayEquals(shortArrayOf(1, 2, 7, 8), stereo.copyOf(4))
    }
}
