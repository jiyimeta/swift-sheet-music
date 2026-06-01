package io.github.jiyimeta.sheetmusic.audio.synth

import io.github.jiyimeta.sheetmusic.audio.MetronomeClickProvider
import io.github.jiyimeta.sheetmusic.audio.MetronomeClickSource
import io.github.jiyimeta.sheetmusic.audio.fakes.FakeJniBridge
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidMetronomeClickResolverTest {
    @Test
    fun clickSamplesBuildsViaBridgeAndReturnsGeneratedBytes() {
        val sf2 = byteArrayOf(10, 20, 30)
        val bridge = FakeJniBridge().apply { buildClickSoundFontResult = sf2 }
        val strong = byteArrayOf(1)
        val weak = byteArrayOf(2)
        val resolver = AndroidMetronomeClickResolver(
            provider = { MetronomeClickSource.ClickSamples(strong, weak) },
            jniBridge = bridge,
        )
        val resolution = resolver.resolve()
        assertTrue(resolution is AndroidMetronomeClickResolver.Resolution.GeneratedSf2)
        assertArrayEquals(sf2, (resolution as AndroidMetronomeClickResolver.Resolution.GeneratedSf2).bytes)
        assertEquals(1, bridge.buildClickSoundFontCalls.size)
        assertArrayEquals(strong, bridge.buildClickSoundFontCalls[0].first)
        assertArrayEquals(weak, bridge.buildClickSoundFontCalls[0].second)
    }

    @Test
    fun clickSamplesFallsBackToGmWhenBridgeReturnsEmpty() {
        val bridge = FakeJniBridge().apply { buildClickSoundFontResult = byteArrayOf() }
        val resolver = AndroidMetronomeClickResolver(
            provider = { MetronomeClickSource.ClickSamples(byteArrayOf(1), byteArrayOf(2)) },
            jniBridge = bridge,
        )
        assertEquals(AndroidMetronomeClickResolver.Resolution.DefaultGm, resolver.resolve())
    }

    @Test
    fun noProviderResolvesToDefaultGm() {
        val resolver = AndroidMetronomeClickResolver(provider = null, jniBridge = FakeJniBridge())
        assertEquals(AndroidMetronomeClickResolver.Resolution.DefaultGm, resolver.resolve())
    }

    @Test
    fun defaultGmSourceResolvesToDefaultGm() {
        val resolver = AndroidMetronomeClickResolver(
            provider = { MetronomeClickSource.DefaultGm },
            jniBridge = FakeJniBridge(),
        )
        assertEquals(AndroidMetronomeClickResolver.Resolution.DefaultGm, resolver.resolve())
    }
}
