package io.github.jiyimeta.sheetmusic.audio.synth

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Ignore
import org.junit.Test
import java.util.concurrent.Executors

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

    /**
     * The invariant `close()` depends on: when `stop()` returns, the writer is *finished*, not merely cancelled.
     *
     * `AudioTrack.write(..., WRITE_BLOCKING)` is a blocking native call rather than a suspension point, so
     * `cancel()` cannot interrupt a writer parked inside it — it only marks the job. `close()` released the track
     * straight after, freeing an AudioTrack the writer was still writing into; the result was a native
     * use-after-free that crashed inside `BpBinder::onLastStrongRef`, rarely enough to look unrelated to the edit
     * that triggered it. The same window let the writer call back into a `Producer` whose synth the caller had
     * already torn down.
     *
     * No AudioTrack here — the point is the join, and the uninterruptible sleep below stands in for the native
     * write. Without the join in `stop()` this fails: the job is still running when `stop()` returns.
     */
    @Test fun stop_waitsForTheWriterToFinish() {
        val stream = OboeStream()
        val dispatcher = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        val scope = CoroutineScope(SupervisorJob() + dispatcher)
        scope.launch {
            // Not a suspension point, so cancellation cannot cut it short — exactly like the native write.
            Thread.sleep(150)
        }

        OboeStream::class.java.getDeclaredField("running").apply { isAccessible = true }.setBoolean(stream, true)
        val scopeField = OboeStream::class.java.getDeclaredField("writerScope").apply { isAccessible = true }
        scopeField.set(stream, scope)

        stream.stop()

        assertTrue(
            "stop() returned while the writer was still running; close() would release the track under it",
            scope.coroutineContext.job.isCompleted,
        )
        dispatcher.close()
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
