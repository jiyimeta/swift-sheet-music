package io.github.jiyimeta.sheetmusic.audio.export

import io.github.jiyimeta.sheetmusic.audio.model.AudioChannelCount
import io.github.jiyimeta.sheetmusic.audio.model.PcmBitDepth
import io.github.jiyimeta.sheetmusic.audio.model.PcmOptions
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

class AiffPcmEncoderTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test fun stereoInt16ProducesFormAiffWithCommAndSsndChunks() {
        val out = File(tmp.root, "test.aiff")
        val opts = PcmOptions(
            sampleRate = 44100,
            bitDepth = PcmBitDepth.Int16,
            channels = AudioChannelCount.Stereo,
        )
        val raf = RandomAccessFile(out, "rw")
        AiffPcmEncoder(opts, 44100, raf.fd).use { enc ->
            enc.appendPcmFloat(floatArrayOf(0.5f), floatArrayOf(-0.5f), 1)
            enc.finish()
        }
        raf.close()
        val bytes = out.readBytes()
        assertEquals("FORM", String(bytes, 0, 4))
        assertEquals("AIFF", String(bytes, 8, 4))
        assertEquals("COMM", String(bytes, 12, 4))
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
        bb.position(20); assertEquals(2, bb.short.toInt())          // channels
        bb.position(22); assertEquals(1, bb.int)                    // numFrames
        bb.position(26); assertEquals(16, bb.short.toInt())         // sampleSize
        // Sample rate at offset 28 (10 bytes 80-bit BE float): 0x40 0x0E 0xAC 0x44
        assertEquals(0x40.toByte(), bytes[28])
        assertEquals(0x0E.toByte(), bytes[29])
        assertEquals(0xAC.toByte(), bytes[30])
        assertEquals(0x44.toByte(), bytes[31])
    }

    @Test fun float32ProducesFormAifcWithFl32Compression() {
        val out = File(tmp.root, "test.aifc")
        val opts = PcmOptions(
            sampleRate = 48000,
            bitDepth = PcmBitDepth.Float32,
            channels = AudioChannelCount.Stereo,
        )
        val raf = RandomAccessFile(out, "rw")
        AiffPcmEncoder(opts, 48000, raf.fd).use { enc ->
            enc.appendPcmFloat(floatArrayOf(0.5f), floatArrayOf(-0.5f), 1)
            enc.finish()
        }
        raf.close()
        val bytes = out.readBytes()
        assertEquals("FORM", String(bytes, 0, 4))
        assertEquals("AIFC", String(bytes, 8, 4))
        // "fl32" appears after the 80-bit sample rate (offset 28+10 = 38)
        assertEquals("fl32", String(bytes, 38, 4))
    }

    @Test fun ssndChunkSizeBackfilled() {
        val out = File(tmp.root, "test_sizes.aiff")
        val opts = PcmOptions(
            sampleRate = 22050,
            bitDepth = PcmBitDepth.Int16,
            channels = AudioChannelCount.Stereo,
        )
        val raf = RandomAccessFile(out, "rw")
        AiffPcmEncoder(opts, 22050, raf.fd).use { enc ->
            enc.appendPcmFloat(FloatArray(100), FloatArray(100), 100)
            enc.finish()
        }
        raf.close()
        val bytes = out.readBytes()
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
        // SSND chunk header at offset 4+4+4+4+4+18 = 38 (for AIFF non-float):
        // FORM(4) + size(4) + formType(4) + COMM(4) + size(4) + commPayload(18) = 38
        val ssndHeader = 38
        assertEquals("SSND", String(bytes, ssndHeader, 4))
        // SSND size = 8 + data bytes = 8 + 2 channels * 2 bytes * 100 frames = 408
        bb.position(ssndHeader + 4); assertEquals(408, bb.int)
        // COMM numFrames = 100
        bb.position(22); assertEquals(100, bb.int)
    }
}
