package io.github.jiyimeta.sheetmusic.audio.recording

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * MediaExtractor + MediaCodec decoding a WAV through the Swift writer into `RecordingPCMCacheFormat`: the header, the
 * size, the samples, mono duplicated onto both channels, and a second prepare reusing the file. On a device only — the
 * decoder and the native library are not on the JVM.
 */
@RunWith(AndroidJUnit4::class)
class RecordingPcmDecoderInstrumentedTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    /** A 16-bit PCM WAV of [samples] (interleaved for [channels]) at [rate]. */
    private fun wav(samples: ShortArray, channels: Int, rate: Int): File {
        val data = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        samples.forEach { data.putShort(it) }
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()); putInt(36 + samples.size * 2); put("WAVE".toByteArray())
            put("fmt ".toByteArray()); putInt(16); putShort(1); putShort(channels.toShort()); putInt(rate)
            putInt(rate * channels * 2); putShort((channels * 2).toShort()); putShort(16)
            put("data".toByteArray()); putInt(samples.size * 2)
        }
        val file = File(context.cacheDir, "decoder-test-${System.nanoTime()}.wav")
        file.writeBytes(header.array() + data.array())
        return file
    }

    @Test fun aMonoWavDecodesToStereoInTheCacheFormat() = runBlocking<Unit> {
        val frames = 4800
        val mono = ShortArray(frames) { ((it % 100) * 200 - 10000).toShort() }
        val source = wav(mono, channels = 1, rate = 48000)
        val directory = File(context.cacheDir, "pcm-cache-test").apply { deleteRecursively() }
        val path = RecordingPcmDecoder(directory).prepare(source.absolutePath, cacheKey = "mono")

        assertEquals(File(directory, "mono-48000.pcm").absolutePath, path)
        val bytes = File(path).readBytes()
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        assertArrayEquals("SMPC".toByteArray(), bytes.copyOfRange(0, 4))
        assertEquals(1, buffer.getInt(4))
        assertEquals(frames, buffer.getInt(8))
        assertEquals(48000, buffer.getInt(12))
        assertEquals(16 + frames * 4, bytes.size)
        for (frame in listOf(0, 1, 99, frames - 1)) {
            assertEquals(mono[frame], buffer.getShort(16 + frame * 4))
            assertEquals(mono[frame], buffer.getShort(16 + frame * 4 + 2))
        }
        source.delete()
    }

    @Test fun aSecondPrepareReusesTheFile() = runBlocking<Unit> {
        val stereo = ShortArray(2 * 4410) { (it * 3).toShort() }
        val source = wav(stereo, channels = 2, rate = 44100)
        val directory = File(context.cacheDir, "pcm-cache-reuse").apply { deleteRecursively() }
        val decoder = RecordingPcmDecoder(directory)
        val first = decoder.prepare(source.absolutePath, cacheKey = "stereo")
        val modified = File(first).lastModified()
        source.delete()
        // The source is gone: only the cache file can answer.
        val second = decoder.prepare(wav(stereo, 2, 44100).absolutePath, cacheKey = "stereo")
        assertEquals(first, second)
        assertEquals(modified, File(second).lastModified())
        assertTrue(File(second).length() == 16L + 4410 * 4)
    }
}
