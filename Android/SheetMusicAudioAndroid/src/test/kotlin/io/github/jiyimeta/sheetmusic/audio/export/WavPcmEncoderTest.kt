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

class WavPcmEncoderTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test fun stereoInt16At44100ProducesValidWavHeader() {
        val out = File(tmp.root, "test.wav")
        val opts = PcmOptions(sampleRate = 44100, bitDepth = PcmBitDepth.Int16, channels = AudioChannelCount.Stereo)
        val raf = RandomAccessFile(out, "rw")
        WavPcmEncoder(opts, 44100, raf.fd).use { enc ->
            enc.appendPcmFloat(floatArrayOf(0.5f), floatArrayOf(-0.5f), 1)
            enc.finish()
        }
        raf.close()
        val bytes = out.readBytes()
        assertEquals("RIFF", String(bytes, 0, 4))
        assertEquals("WAVE", String(bytes, 8, 4))
        assertEquals("fmt ", String(bytes, 12, 4))
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        bb.position(20); assertEquals(1, bb.short.toInt())          // format tag = 1 (PCM)
        bb.position(22); assertEquals(2, bb.short.toInt())          // channels = 2
        bb.position(24); assertEquals(44100, bb.int)                // sample rate
        bb.position(34); assertEquals(16, bb.short.toInt())         // bits per sample
        // data chunk size = 2 channels * 2 bytes * 1 frame = 4
        bb.position(40); assertEquals(4, bb.int)
        // First sample (LE int16): 0.5 → 16383
        bb.position(44); assertEquals(16383, bb.short.toInt())
        // Second sample (LE int16): -0.5 → -16383
        bb.position(46); assertEquals(-16383, bb.short.toInt())
    }

    @Test fun monoFloat32EncodesFloatFormatTag() {
        val out = File(tmp.root, "test_float.wav")
        val opts = PcmOptions(sampleRate = 48000, bitDepth = PcmBitDepth.Float32, channels = AudioChannelCount.Mono)
        val raf = RandomAccessFile(out, "rw")
        WavPcmEncoder(opts, 48000, raf.fd).use { enc ->
            enc.appendPcmFloat(floatArrayOf(1.0f, 0.5f), floatArrayOf(0f, 0f), 2)
            enc.finish()
        }
        raf.close()
        val bytes = out.readBytes()
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        bb.position(20); assertEquals(3, bb.short.toInt())  // WAVE_FORMAT_IEEE_FLOAT
        bb.position(22); assertEquals(1, bb.short.toInt())  // mono
        // First float sample at byte 44
        assertEquals(1.0f, ByteBuffer.wrap(bytes, 44, 4).order(ByteOrder.LITTLE_ENDIAN).float, 0f)
        assertEquals(0.5f, ByteBuffer.wrap(bytes, 48, 4).order(ByteOrder.LITTLE_ENDIAN).float, 0f)
    }

    @Test fun riffAndDataSizesAreBackfilled() {
        val out = File(tmp.root, "test_sizes.wav")
        val opts = PcmOptions(sampleRate = 22050, bitDepth = PcmBitDepth.Int16, channels = AudioChannelCount.Stereo)
        val raf = RandomAccessFile(out, "rw")
        WavPcmEncoder(opts, 22050, raf.fd).use { enc ->
            enc.appendPcmFloat(FloatArray(100), FloatArray(100), 100)
            enc.finish()
        }
        raf.close()
        val bytes = out.readBytes()
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        // data chunk size = 2 channels * 2 bytes * 100 frames = 400
        bb.position(40); assertEquals(400, bb.int)
        // RIFF size = 36 + 400 = 436
        bb.position(4); assertEquals(436, bb.int)
        // Total file size = 44 (header) + 400 = 444
        assertEquals(444, bytes.size)
    }
}
