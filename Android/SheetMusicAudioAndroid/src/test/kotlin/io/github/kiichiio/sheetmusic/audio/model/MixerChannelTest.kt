package io.github.kiichiio.sheetmusic.audio.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class MixerChannelTest {
    @Test fun defaultValues() {
        val channel = MixerChannel(staffIndex = 0, displayName = "Piano")
        assertEquals(1.0f, channel.volume)
        assertFalse(channel.isMuted)
        assertFalse(channel.isSoloed)
        assertFalse(channel.effectiveMute)
    }

    @Test fun customValues() {
        val channel = MixerChannel(
            staffIndex = 2,
            displayName = "Violin",
            volume = 0.5f,
            isMuted = true,
            isSoloed = false,
            effectiveMute = true,
        )
        assertEquals(2, channel.staffIndex)
        assertEquals("Violin", channel.displayName)
        assertEquals(0.5f, channel.volume)
        assertEquals(true, channel.isMuted)
        assertEquals(true, channel.effectiveMute)
    }

    @Test fun dataClassEquality() {
        val a = MixerChannel(staffIndex = 1, displayName = "Flute", volume = 0.8f)
        val b = MixerChannel(staffIndex = 1, displayName = "Flute", volume = 0.8f)
        assertEquals(a, b)
    }
}
