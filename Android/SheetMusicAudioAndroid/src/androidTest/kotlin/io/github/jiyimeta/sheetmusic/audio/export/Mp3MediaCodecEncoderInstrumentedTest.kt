package io.github.jiyimeta.sheetmusic.audio.export

import android.os.ParcelFileDescriptor
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.jiyimeta.sheetmusic.audio.AudioBackendException
import io.github.jiyimeta.sheetmusic.audio.model.AudioChannelCount
import io.github.jiyimeta.sheetmusic.audio.model.CompressedOptions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class Mp3MediaCodecEncoderInstrumentedTest {
    @Test fun mp3EncoderEitherWritesValidMp3OrThrowsFormatUnsupported() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val out = File(ctx.cacheDir, "test_mp3.mp3")
        if (out.exists()) out.delete()
        val opts = CompressedOptions(
            sampleRate = 44100, bitRate = 128_000, channels = AudioChannelCount.Stereo,
        )
        try {
            ParcelFileDescriptor.open(
                out,
                ParcelFileDescriptor.MODE_READ_WRITE or
                    ParcelFileDescriptor.MODE_CREATE or
                    ParcelFileDescriptor.MODE_TRUNCATE,
            ).use { fd ->
                Mp3MediaCodecEncoder(opts, 44100, fd).use { enc ->
                    val left = FloatArray(4096)
                    val right = FloatArray(4096)
                    repeat(11) { enc.appendPcmFloat(left, right, 4096) }
                    enc.finish()
                }
            }
            // If we got here, encoder is available — file should look like a valid MP3
            assertTrue("file should exist and be > 1000 bytes", out.length() > 1000)
            val first = out.inputStream().use { stream -> ByteArray(2).also { stream.read(it) } }
            // MP3 frame sync: 0xFF followed by byte whose top 3 bits are 0xE0
            assertEquals(0xFF.toByte(), first[0])
            assertTrue(
                "second byte should have frame sync bits set",
                (first[1].toInt() and 0xE0) == 0xE0,
            )
        } catch (e: AudioBackendException.FormatUnsupportedOnThisOS) {
            // Acceptable: not all devices have an MP3 encoder.
            assertNotNull(e.format)
        }
    }
}
