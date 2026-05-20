package io.github.jiyimeta.sheetmusic.audio.export

import org.junit.Assert.assertEquals
import org.junit.Test

class Ieee80BitFloatTest {
    @Test fun encodes44100() {
        val bytes = Ieee80BitFloat.encode(44100.0)
        // Reference: 40 0E AC 44 00 00 00 00 00 00
        assertEquals(0x40.toByte(), bytes[0])
        assertEquals(0x0E.toByte(), bytes[1])
        assertEquals(0xAC.toByte(), bytes[2])
        assertEquals(0x44.toByte(), bytes[3])
        assertEquals(0x00.toByte(), bytes[4])
    }

    @Test fun encodes48000() {
        val bytes = Ieee80BitFloat.encode(48000.0)
        // Reference: 40 0E BB 80 00 00 00 00 00 00
        assertEquals(0x40.toByte(), bytes[0])
        assertEquals(0x0E.toByte(), bytes[1])
        assertEquals(0xBB.toByte(), bytes[2])
        assertEquals(0x80.toByte(), bytes[3])
    }
}
