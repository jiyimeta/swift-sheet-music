package io.github.jiyimeta.sheetmusic.audio.export

import android.media.MediaMetadataRetriever
import android.os.ParcelFileDescriptor
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.jiyimeta.sheetmusic.audio.model.AudioChannelCount
import io.github.jiyimeta.sheetmusic.audio.model.CompressedOptions
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class AacM4aEncoderInstrumentedTest {
    @Test fun stereoAac128kbpsProducesValidM4a() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val out = File(ctx.cacheDir, "test_aac.m4a")
        if (out.exists()) out.delete()
        val opts = CompressedOptions(
            sampleRate = 44100, bitRate = 128_000, channels = AudioChannelCount.Stereo,
        )
        ParcelFileDescriptor.open(
            out,
            ParcelFileDescriptor.MODE_READ_WRITE or
                ParcelFileDescriptor.MODE_CREATE or
                ParcelFileDescriptor.MODE_TRUNCATE,
        ).use { fd ->
            AacM4aEncoder(opts, 44100, fd).use { enc ->
                val left = FloatArray(4096)
                val right = FloatArray(4096)
                // 11 buffers of 4096 frames @ 44100 ≈ 1.02 seconds.
                repeat(11) { enc.appendPcmFloat(left, right, 4096) }
                enc.finish()
            }
        }
        assertTrue("output file should exist", out.exists())
        assertTrue("file size should be > 1000 bytes", out.length() > 1000)
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(out.absolutePath)
            val mime = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)
            val durationMs = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0
            assertNotNull("mime should be non-null", mime)
            assertTrue(
                "mime should be MP4/M4A audio (got: $mime)",
                mime!!.contains("mp4") || mime.contains("m4a") || mime.contains("aac"),
            )
            assertTrue("duration should be ~1 second (got $durationMs ms)", durationMs in 800..1200)
        } finally {
            retriever.release()
        }
    }
}
