package io.github.jiyimeta.sheetmusic.audio.recording

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** When [RecordingPcmDecoder] looks for a cache file again once the decoder has said what rate it puts out. */
class RecordingPcmCacheLookupTest {
    /** A writer whose directory holds [files] (`<key>-<Hz>`); it records every rate it was asked about. */
    private class Writer(private val files: Set<String>) : RecordingPcmWriterCalls {
        val lookups = mutableListOf<Double>()

        override fun existing(directory: String, cacheKey: String, sampleRate: Double): String {
            lookups += sampleRate
            val name = "$cacheKey-${sampleRate.toInt()}"
            return if (name in files) "$directory/$name.pcm" else ""
        }

        override fun open(directory: String, cacheKey: String, sampleRate: Double) = 0L
        override fun append(writer: Long, samples: ShortArray, frameCount: Int, channels: Int) = 0
        override fun finish(writer: Long) = ""
        override fun cancel(writer: Long) {}
    }

    @Test fun `a file written at the decoder's doubled rate is found once the output format says so`() {
        // HE-AAC: the container says 22050 Hz, SBR decodes to 44100 Hz, and the file was written at the latter.
        val writer = Writer(setOf("take-44100"))
        val path = writer.existingAfterFormatChange(
            "/cache", "take", sourceRate = 22050, outputRate = 44100, writing = false,
        )
        assertEquals("/cache/take-44100.pcm", path)
        assertEquals(listOf(44100.0), writer.lookups)
    }

    @Test fun `no file at the output rate means decoding`() {
        val writer = Writer(emptySet())
        assertNull(writer.existingAfterFormatChange("/cache", "take", 22050, 44100, writing = false))
    }

    @Test fun `the container's own rate is not looked up twice, nor any once a file is being written`() {
        val writer = Writer(setOf("take-48000", "take-96000"))
        assertNull(writer.existingAfterFormatChange("/cache", "take", 48000, 48000, writing = false))
        assertNull(writer.existingAfterFormatChange("/cache", "take", 48000, 96000, writing = true))
        assertEquals(emptyList<Double>(), writer.lookups)
    }
}
