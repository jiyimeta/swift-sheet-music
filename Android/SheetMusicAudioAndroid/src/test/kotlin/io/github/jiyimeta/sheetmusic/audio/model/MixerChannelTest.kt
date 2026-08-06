package io.github.jiyimeta.sheetmusic.audio.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class MixerChannelTest {
    @Test fun defaultValues() {
        val channel = MixerChannel(partIndex = 0, ordinal = 0, liveChannel = 0, displayName = "Piano")
        assertEquals(1.0f, channel.volume)
        assertFalse(channel.isMuted)
        assertFalse(channel.isSoloed)
        assertFalse(channel.effectiveMute)
    }

    @Test fun customValues() {
        val channel = MixerChannel(
            partIndex = 1,
            ordinal = 0,
            liveChannel = 2,
            displayName = "Violin",
            volume = 0.5f,
            isMuted = true,
            isSoloed = false,
            effectiveMute = true,
        )
        assertEquals(1, channel.partIndex)
        assertEquals(0, channel.ordinal)
        assertEquals(2, channel.liveChannel)
        assertEquals("Violin", channel.displayName)
        assertEquals(0.5f, channel.volume)
        assertEquals(true, channel.isMuted)
        assertEquals(true, channel.effectiveMute)
    }

    @Test fun dataClassEquality() {
        val a = MixerChannel(partIndex = 0, ordinal = 1, liveChannel = 1, displayName = "Flute", volume = 0.8f)
        val b = MixerChannel(partIndex = 0, ordinal = 1, liveChannel = 1, displayName = "Flute", volume = 0.8f)
        assertEquals(a, b)
    }

    @Test
    fun mixerChannelDefaultsProgramToNull() {
        val ch = MixerChannel(partIndex = 0, ordinal = 0, liveChannel = 0, displayName = "Staff 1")
        assertNull(ch.program)
    }

    @Test
    fun mixerChannelHoldsProgramValue() {
        val ch = MixerChannel(partIndex = 0, ordinal = 0, liveChannel = 0, displayName = "Staff 1", program = 24)
        assertEquals(24, ch.program)
    }
}
