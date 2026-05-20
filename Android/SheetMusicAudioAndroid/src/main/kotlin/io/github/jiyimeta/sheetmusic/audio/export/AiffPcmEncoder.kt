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
 * AIFF / AIFC big-endian PCM encoder.
 *
 * Writes a `FORM` container with two chunks:
 *  - `COMM` — channels, frame count, sample size, 80-bit BE sample rate
 *    (plus, for AIFC float32, a `"fl32"` compression code and a Pascal
 *    compression name).
 *  - `SSND` — `offset = 0`, `blockSize = 0`, raw big-endian PCM samples.
 *
 * `formType` is `AIFF` for integer PCM and `AIFC` for float32. Chunk
 * sizes (`FORM`, `SSND`) and `COMM.numFrames` are backfilled in [finish].
 *
 * The constructor takes a raw [FileDescriptor] (not [android.os.ParcelFileDescriptor])
 * so JVM unit tests can drive it with `RandomAccessFile(file, "rw").fd`. The
 * encoder owns a [FileOutputStream] wrapping the fd and uses its [FileChannel]
 * for random-access seek when back-filling the size fields.
 */
internal class AiffPcmEncoder(
    private val options: PcmOptions,
    @Suppress("UNUSED_PARAMETER") sampleRate: Int,
    fd: FileDescriptor,
) : AudioFileEncoder {
    private val fos = FileOutputStream(fd)
    private val channel: FileChannel = fos.channel
    private val mono = options.channels == AudioChannelCount.Mono
    private val isFloat = options.bitDepth == PcmBitDepth.Float32
    private val bytesPerSample: Int = when (options.bitDepth) {
        PcmBitDepth.Int16 -> 2
        PcmBitDepth.Int24 -> 3
        PcmBitDepth.Int32 -> 4
        PcmBitDepth.Float32 -> 4
    }
    private val frameBytes: Int = bytesPerSample * options.channels.rawValue
    private var frameCount: Int = 0
    private var finished = false

    // COMM payload size:
    //   - base 18 = channels(2) + numFrames(4) + sampleSize(2) + sampleRate(10)
    //   - AIFC adds 10 = compression code "fl32" (4) + pascal name "\x04fl32\0" (6)
    private val commPayloadSize: Int = if (isFloat) 18 + 4 + 6 else 18

    // Offset of the SSND chunk header byte:
    //   FORM(4) + FORM-size(4) + formType(4) + COMM(4) + comm-size(4) + commPayloadSize
    private val ssndHeaderOffset: Long = 4L + 4L + 4L + 4L + 4L + commPayloadSize.toLong()

    // First byte of raw sample data: SSND header (4) + SSND-size (4)
    //                              + offset (4) + blockSize (4)
    private val dataStartOffset: Long = ssndHeaderOffset + 4L + 4L + 4L + 4L

    init { writeHeader() }

    private fun writeHeader() {
        val formType = if (isFloat) "AIFC" else "AIFF"
        val buf = ByteBuffer.allocate(dataStartOffset.toInt()).order(ByteOrder.BIG_ENDIAN)
        buf.put("FORM".toByteArray())
        buf.putInt(0)                                                  // FORM size — backfill
        buf.put(formType.toByteArray())
        buf.put("COMM".toByteArray())
        buf.putInt(commPayloadSize)
        buf.putShort(options.channels.rawValue.toShort())              // channels
        buf.putInt(0)                                                  // numFrames — backfill
        buf.putShort((bytesPerSample * 8).toShort())                   // sampleSize
        buf.put(Ieee80BitFloat.encode(options.sampleRate.toDouble()))  // 10 bytes
        if (isFloat) {
            buf.put("fl32".toByteArray())                              // compression code
            // Pascal string: length byte + chars; padded to even total length.
            buf.put(
                byteArrayOf(
                    0x04,
                    'f'.code.toByte(),
                    'l'.code.toByte(),
                    '3'.code.toByte(),
                    '2'.code.toByte(),
                    0,
                ),
            )
        }
        buf.put("SSND".toByteArray())
        buf.putInt(0)                                                  // SSND size — backfill
        buf.putInt(0)                                                  // offset (always 0)
        buf.putInt(0)                                                  // blockSize (always 0)
        buf.flip()
        channel.write(buf)
    }

    override fun appendPcmFloat(left: FloatArray, right: FloatArray, frames: Int) {
        val payload = ByteArray(frames * frameBytes)
        when (options.bitDepth) {
            PcmBitDepth.Int16 ->
                PcmSampleConversion.floatToInt16InterleavedBE(left, right, frames, mono, payload)
            PcmBitDepth.Int24 ->
                PcmSampleConversion.floatToInt24BE(left, right, frames, mono, payload)
            PcmBitDepth.Int32 ->
                PcmSampleConversion.floatToInt32BE(left, right, frames, mono, payload)
            PcmBitDepth.Float32 ->
                PcmSampleConversion.floatToFloat32BE(left, right, frames, mono, payload)
        }
        channel.write(ByteBuffer.wrap(payload))
        frameCount += frames
    }

    override fun finish() {
        if (finished) return
        val dataBytes = frameCount * frameBytes
        // FORM size = total file size - 8.
        val formSize = (dataStartOffset.toInt() + dataBytes) - 8
        writeIntBE(formSize, at = 4)
        // COMM.numFrames sits at offset
        //   FORM(4) + FORM-size(4) + formType(4) + COMM(4) + comm-size(4) + channels(2) = 22
        writeIntBE(frameCount, at = 22)
        // SSND size = 8 (offset + blockSize) + sample-data bytes.
        writeIntBE(8 + dataBytes, at = ssndHeaderOffset + 4)
        // Restore position to end of data so any subsequent append behaves sensibly.
        channel.position(dataStartOffset + dataBytes)
        try { fos.fd.sync() } catch (_: Throwable) {}
        finished = true
    }

    override fun close() {
        try { if (!finished) fos.fd.sync() } catch (_: Throwable) {}
        try { channel.close() } catch (_: Throwable) {}
        fos.close()
    }

    private fun writeIntBE(value: Int, at: Long) {
        val bb = ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN)
        bb.putInt(value)
        bb.flip()
        channel.position(at)
        channel.write(bb)
    }
}
