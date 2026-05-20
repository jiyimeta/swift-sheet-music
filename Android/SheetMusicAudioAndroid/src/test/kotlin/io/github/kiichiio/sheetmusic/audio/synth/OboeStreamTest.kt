package io.github.kiichiio.sheetmusic.audio.synth

import org.junit.Assert.assertEquals
import org.junit.Ignore
import org.junit.Test

/**
 * JVM unit tests for [OboeStream].
 *
 * Tests that touch [android.media.AudioTrack] are skipped with @Ignore
 * because AudioTrack requires an Android runtime. Only pure-Kotlin
 * logic (volatile state mutations) is tested here.
 */
class OboeStreamTest {

    @Test fun setMasterVolume_updatesVolatileField() {
        val stream = OboeStream(sampleRate = 44_100, framesPerBuffer = 256)
        // Access the field via reflection to avoid calling open() / play()
        // which require AudioTrack.
        stream.setMasterVolume(0.5f)
        val field = OboeStream::class.java.getDeclaredField("masterVolume")
        field.isAccessible = true
        assertEquals(0.5f, field.getFloat(stream), 0.0001f)
    }

    @Test fun setMasterVolume_defaultIsOne() {
        val stream = OboeStream()
        val field = OboeStream::class.java.getDeclaredField("masterVolume")
        field.isAccessible = true
        assertEquals(1.0f, field.getFloat(stream), 0.0001f)
    }

    @Test fun setProducer_updatesAtomicReference() {
        val stream = OboeStream()
        val producerField = OboeStream::class.java.getDeclaredField("producer")
        producerField.isAccessible = true

        @Suppress("UNCHECKED_CAST")
        val ref = producerField.get(stream) as java.util.concurrent.atomic.AtomicReference<*>

        assertEquals(null, ref.get())

        val fakeProducer = OboeStream.Producer { _, _, _ -> }
        stream.setProducer(fakeProducer)
        assertEquals(fakeProducer, ref.get())

        stream.setProducer(null)
        assertEquals(null, ref.get())
    }

    @Ignore("requires Android instrumentation — AudioTrack is not available on JVM")
    @Test fun open_doesNotThrow() {
        // This test must run on an Android device or emulator.
        val stream = OboeStream()
        stream.open()
        stream.close()
    }

    @Ignore("requires Android instrumentation — AudioTrack is not available on JVM")
    @Test fun play_andStop_doNotCrash() {
        val stream = OboeStream()
        stream.open()
        stream.play()
        stream.stop()
        stream.close()
    }
}
