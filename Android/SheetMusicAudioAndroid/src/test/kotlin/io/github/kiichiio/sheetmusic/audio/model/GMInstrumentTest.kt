package io.github.kiichiio.sheetmusic.audio.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class GMInstrumentTest {
    @Test
    fun gmHasOneHundredTwentyEightPatches() {
        assertEquals(128, GMInstrument.values().size)
    }

    @Test
    fun program0IsAcousticGrandPiano() {
        val p = GMInstrument.values().first { it.program == 0 }
        assertEquals("Acoustic Grand Piano", p.displayName)
    }

    @Test
    fun program40IsViolin() {
        val p = GMInstrument.values().first { it.program == 40 }
        assertEquals("Violin", p.displayName)
    }

    @Test
    fun forProgramReturnsViolinAt40() {
        assertEquals(GMInstrument.VIOLIN, GMInstrument.forProgram(40))
    }

    @Test
    fun forProgramReturnsNullForOutOfRange() {
        assertNull(GMInstrument.forProgram(-1))
        assertNull(GMInstrument.forProgram(128))
    }
}
