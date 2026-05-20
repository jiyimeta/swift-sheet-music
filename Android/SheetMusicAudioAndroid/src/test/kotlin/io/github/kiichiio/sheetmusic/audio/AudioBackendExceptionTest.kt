package io.github.kiichiio.sheetmusic.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioBackendExceptionTest {
    @Test fun noSoundfontMessage() {
        val ex: AudioBackendException = AudioBackendException.NoSoundfont()
        assertEquals("No SoundFont available", ex.message)
        assertTrue(ex is AudioBackendException.NoSoundfont)
    }

    @Test fun streamUnavailableMessage() {
        val ex = AudioBackendException.StreamUnavailable("device busy")
        assertEquals("Audio stream open failed: device busy", ex.message)
    }

    @Test fun invalidScoreHandleMessage() {
        val ex = AudioBackendException.InvalidScoreHandle()
        assertEquals("Score handle was not recognized", ex.message)
    }

    @Test fun emptyScoreMessage() {
        val ex = AudioBackendException.EmptyScore()
        assertEquals("Score has zero staves", ex.message)
    }

    @Test fun tooManyStavesPayload() {
        val ex = AudioBackendException.TooManyStaves(staffCount = 32)
        assertEquals(32, ex.staffCount)
        assertEquals("Score has 32 staves; v0 supports up to 16", ex.message)
    }

    @Test fun fluidSynthInitMessage() {
        val ex = AudioBackendException.FluidSynthInit("out of memory")
        assertEquals("FluidSynth initialization failed: out of memory", ex.message)
    }
}
