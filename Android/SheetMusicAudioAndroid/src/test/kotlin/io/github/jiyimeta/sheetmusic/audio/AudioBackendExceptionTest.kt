package io.github.jiyimeta.sheetmusic.audio

import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
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

    @Test fun noScorePreparedHasReadableMessage() {
        val e = AudioBackendException.NoScorePrepared()
        assertNotNull(e.message)
        assertTrue(e.message!!.contains("No score") || e.message!!.contains("prepared"))
    }

    @Test fun rangeNotInTimelineHasReadableMessage() {
        val e = AudioBackendException.RangeNotInTimeline()
        assertNotNull(e.message)
        assertTrue(e.message!!.contains("range") || e.message!!.contains("timeline"))
    }

    @Test fun formatUnsupportedCarriesFormat() {
        val fmt = AudioFileFormat.Mp3()
        val e = AudioBackendException.FormatUnsupportedOnThisOS(fmt)
        assertEquals(fmt, e.format)
    }

    @Test fun fileWriteFailedHasCause() {
        val cause = RuntimeException("disk full")
        val e = AudioBackendException.FileWriteFailed(cause)
        assertSame(cause, e.cause)
    }

    @Test fun cancelledIsAudioBackendException() {
        val e = AudioBackendException.Cancelled()
        assertTrue(e is AudioBackendException)
        assertNotNull(e.message)
    }
}
