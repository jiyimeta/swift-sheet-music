package io.github.jiyimeta.sheetmusic.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class MetronomeClickSourceTest {
    @Test
    fun clickSamplesHoldsBothByteArrays() {
        val strong = byteArrayOf(1, 2, 3)
        val weak = byteArrayOf(4, 5)
        val source = MetronomeClickSource.ClickSamples(strong, weak)
        assertEquals(strong, source.strongWav)
        assertEquals(weak, source.weakWav)
    }

    @Test
    fun defaultGmIsSingleton() {
        assertEquals(MetronomeClickSource.DefaultGm, MetronomeClickSource.DefaultGm)
        assertNotEquals(
            MetronomeClickSource.DefaultGm as Any,
            MetronomeClickSource.ClickSamples(byteArrayOf(), byteArrayOf()) as Any,
        )
    }

    @Test
    fun providerReturnsConfiguredSource() {
        val provider = MetronomeClickProvider { MetronomeClickSource.DefaultGm }
        assertEquals(MetronomeClickSource.DefaultGm, provider.metronomeClickSource())
    }
}
