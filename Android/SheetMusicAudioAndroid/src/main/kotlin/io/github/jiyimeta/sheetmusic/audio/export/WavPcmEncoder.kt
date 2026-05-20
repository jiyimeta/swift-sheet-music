package io.github.jiyimeta.sheetmusic.audio.export

import io.github.jiyimeta.sheetmusic.audio.model.AudioChannelCount
import io.github.jiyimeta.sheetmusic.audio.model.PcmBitDepth
import io.github.jiyimeta.sheetmusic.audio.model.PcmOptions
import java.io.FileDescriptor
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel

/**
 * WAV / RIFF PCM encoder. Writes a 44-byte canonical header (16-byte
 * `fmt ` chunk + `data` chunk), backfilling the RIFF and data sizes in
 * [finish]. Supports Int16 / Int24 / Int32 (format tag `1`, WAVE_FORMAT_PCM)
 * and Float32 (format tag `3`, WAVE_FORMAT_IEEE_FLOAT). Both mono and
 * stereo channel layouts are supported.
 *
 * Sample byte order is little-endian.
 *
 * The constructor takes a raw [FileDescriptor] (not [android.os.ParcelFileDescriptor])
 * so JVM unit tests can drive it with `RandomAccessFile(file, "rw").fd`. The
 * encoder owns a [FileOutputStream] wrapping the fd and uses its [FileChannel]
 * for random-access seek when back-filling the size fields.
 */
internal class WavPcmEncoder(
    private val options: PcmOptions,
    @Suppress("UNUSED_PARAMETER") sampleRate: Int,
    fd: FileDescriptor,
) : AudioFileEncoder {
    private val fos = FileOutputStream(fd)
    private val channel: FileChannel = fos.channel
    private val mono = options.channels == AudioChannelCount.Mono
    private val bytesPerSample: Int = when (options.bitDepth) {
        PcmBitDepth.Int16 -> 2
        PcmBitDepth.Int24 -> 3
        PcmBitDepth.Int32 -> 4
        PcmBitDepth.Float32 -> 4
    }
    private val frameBytes: Int = bytesPerSample * options.channels.rawValue
    private var dataBytesWritten: Int = 0
    private var finished = false

    init { writeHeader() }

    private fun writeHeader() {
        val isFloat = options.bitDepth == PcmBitDepth.Float32
        val fmtChunkSize = 16
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray())
        header.putInt(0)  // RIFF size — backfilled in finish()
        header.put("WAVE".toByteArray())
        header.put("fmt ".toByteArray())
        header.putInt(fmtChunkSize)
        header.putShort(if (isFloat) 3.toShort() else 1.toShort())  // format tag
        header.putShort(options.channels.rawValue.toShort())
        header.putInt(options.sampleRate)
        header.putInt(options.sampleRate * frameBytes)  // byteRate
        header.putShort(frameBytes.toShort())  // blockAlign
        header.putShort((bytesPerSample * 8).toShort())  // bits per sample
        header.put("data".toByteArray())
        header.putInt(0)  // data size — backfilled in finish()
        header.flip()
        channel.write(header)
    }

    override fun appendPcmFloat(left: FloatArray, right: FloatArray, frames: Int) {
        val payload = ByteArray(frames * frameBytes)
        when (options.bitDepth) {
            PcmBitDepth.Int16 -> {
                val tmp = ShortArray(frames * options.channels.rawValue)
                PcmSampleConversion.floatToInt16Interleaved(left, right, frames, mono, tmp)
                val bb = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
                for (s in tmp) bb.putShort(s)
            }
            PcmBitDepth.Int24 -> PcmSampleConversion.floatToInt24LE(left, right, frames, mono, payload)
            PcmBitDepth.Int32 -> PcmSampleConversion.floatToInt32LE(left, right, frames, mono, payload)
            PcmBitDepth.Float32 -> PcmSampleConversion.floatToFloat32LE(left, right, frames, mono, payload)
        }
        channel.write(ByteBuffer.wrap(payload))
        dataBytesWritten += payload.size
    }

    override fun finish() {
        if (finished) return
        val riffSize = 36 + dataBytesWritten
        writeIntLE(riffSize, at = 4)
        writeIntLE(dataBytesWritten, at = 40)
        // Restore position to end of data so any subsequent append behaves sensibly.
        channel.position(44L + dataBytesWritten)
        try { fos.fd.sync() } catch (_: Throwable) {}
        finished = true
    }

    override fun close() {
        try { if (!finished) fos.fd.sync() } catch (_: Throwable) {}
        try { channel.close() } catch (_: Throwable) {}
        fos.close()
    }

    private fun writeIntLE(value: Int, at: Long) {
        val bb = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN)
        bb.putInt(value)
        bb.flip()
        channel.position(at)
        channel.write(bb)
    }
}
