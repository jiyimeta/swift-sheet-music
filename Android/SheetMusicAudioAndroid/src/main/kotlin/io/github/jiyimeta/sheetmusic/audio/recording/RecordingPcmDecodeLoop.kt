package io.github.jiyimeta.sheetmusic.audio.recording

import android.media.MediaCodec
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ensureActive
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.coroutines.coroutineContext

/**
 * The MediaCodec and MediaExtractor calls the decode loop ([decodeToCache]) makes, apart so a JVM test can drive the
 * loop with a fake decoder. [RecordingPcmDecoder] adapts the real pair.
 */
internal interface DecodeCodec {
    /** A free input buffer's index, or a negative value when none frees up within [timeoutMicros]. */
    fun dequeueInputBuffer(timeoutMicros: Long): Int

    /**
     * Fills input buffer [index] with the source's next sample and queues it; once the source has none left, queues it
     * empty with the end-of-stream flag instead and returns false.
     */
    fun queueInput(index: Int): Boolean

    /**
     * MediaCodec's `dequeueOutputBuffer`: a buffer's index with [info] describing it, or
     * [MediaCodec.INFO_OUTPUT_FORMAT_CHANGED], or another negative `INFO_` code when nothing came within
     * [timeoutMicros].
     */
    fun dequeueOutputBuffer(info: DecodedBufferInfo, timeoutMicros: Long): Int

    /** Output buffer [index]'s bytes, or null when the codec has none for it. */
    fun outputBuffer(index: Int): ByteBuffer?

    /** Hands output buffer [index] back to the codec. */
    fun releaseOutputBuffer(index: Int)

    /** The PCM the codec puts out, read after [MediaCodec.INFO_OUTPUT_FORMAT_CHANGED]. */
    fun outputFormat(): DecodedFormat
}

/** Where a dequeued output buffer's samples lie in its bytes, and whether it is the codec's last. */
internal class DecodedBufferInfo {
    var offset = 0
    var size = 0
    var endOfStream = false
}

/** The PCM a codec puts out: [channels] interleaved at [sampleRate], 32-bit float when [floatSamples], else 16-bit. */
internal data class DecodedFormat(val channels: Int, val sampleRate: Int, val floatSamples: Boolean)

/** How long the decode loop waits for output once neither side of the codec can move. */
internal const val DECODE_WAIT_MICROS = 10_000L

/**
 * Runs [codec] to its end of stream and writes what it puts out through [writer] as `<cacheKey>-<Hz>.pcm` in
 * [directory], returning the file's path — or, when the output format names a rate other than the container's
 * [sourceRate], the path of a valid file already there for it ([existingAfterFormatChange]). Until the codec says
 * otherwise its output is taken to be 16-bit [sourceChannels] at [sourceRate].
 *
 * Each turn feeds every input buffer the codec has free and takes one output buffer, neither waiting, so output that is
 * ready is drained back to back with input refilled as buffers free up. A turn waits — on the output side, at most
 * [waitMicros] — only after a turn in which the codec had no output, and only when no input could go in either: a busy
 * codec holds every input buffer, so waiting on the input side while output is coming is what held the decode near 2×
 * realtime.
 *
 * Cancelling the caller stops it between buffers and abandons any file begun.
 *
 * @throws RecordingPcmDecoder.DecodeException when the codec puts out nothing, or the file cannot be made or written.
 */
internal suspend fun decodeToCache(
    codec: DecodeCodec,
    writer: RecordingPcmWriterCalls,
    directory: String,
    cacheKey: String,
    sourceRate: Int,
    sourceChannels: Int,
    waitMicros: Long = DECODE_WAIT_MICROS,
): String {
    var handle = 0L
    try {
        var format = DecodedFormat(channels = sourceChannels, sampleRate = sourceRate, floatSamples = false)
        var scratch = ShortArray(0)
        val info = DecodedBufferInfo()
        var inputDone = false
        var outputIdle = false
        while (true) {
            coroutineContext.ensureActive()
            var fed = false
            while (!inputDone) {
                val inIndex = codec.dequeueInputBuffer(0L)
                if (inIndex < 0) break
                inputDone = !codec.queueInput(inIndex)
                fed = true
            }
            val outIndex = codec.dequeueOutputBuffer(info, if (outputIdle && !fed) waitMicros else 0L)
            outputIdle = false
            when {
                outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    format = codec.outputFormat()
                    // The file is named for the rate the decoder puts out, which HE-AAC's SBR doubles from the
                    // container's: a file an earlier decode wrote is found only under that rate.
                    writer.existingAfterFormatChange(
                        directory, cacheKey, sourceRate, format.sampleRate, writing = handle != 0L,
                    )?.let { return it }
                }
                outIndex >= 0 -> {
                    val buffer = codec.outputBuffer(outIndex)
                    if (buffer != null && info.size > 0) {
                        if (handle == 0L) {
                            handle = writer.open(directory, cacheKey, format.sampleRate.toDouble())
                            if (handle == 0L) {
                                throw RecordingPcmDecoder.DecodeException("cannot create the cache file in $directory")
                            }
                        }
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        buffer.order(ByteOrder.LITTLE_ENDIAN)
                        val bytesPerSample = if (format.floatSamples) 4 else 2
                        val samples = info.size / bytesPerSample
                        val raw = if (format.floatSamples) {
                            val floats = FloatArray(samples).also { buffer.asFloatBuffer().get(it) }
                            PcmConversion.int16(floats)
                        } else {
                            ShortArray(samples).also { buffer.asShortBuffer().get(it) }
                        }
                        val frames = samples / format.channels.coerceAtLeast(1)
                        val (stereo, channels) = PcmConversion.atMostStereo(raw, frames, format.channels, scratch)
                        if (format.channels > 2) scratch = stereo
                        if (frames > 0 && writer.append(handle, stereo, frames, channels) != 0) {
                            // The `finally` cancels the writer, which releases it.
                            throw RecordingPcmDecoder.DecodeException("cannot write the cache file")
                        }
                    }
                    codec.releaseOutputBuffer(outIndex)
                    if (info.endOfStream) break
                }
                // INFO_TRY_AGAIN_LATER (or the long-deprecated INFO_OUTPUT_BUFFERS_CHANGED): nothing to take.
                else -> outputIdle = true
            }
        }
        if (handle == 0L) throw RecordingPcmDecoder.DecodeException("the recording decodes to nothing")
        val path = writer.finish(handle)
        handle = 0L
        if (path.isEmpty()) throw RecordingPcmDecoder.DecodeException("cannot finish the cache file")
        return path
    } finally {
        if (handle != 0L) writer.cancel(handle)
    }
}

/**
 * [block] with a codec failure — an [IllegalStateException], which `MediaCodec.CodecException` is — reported as a
 * [RecordingPcmDecoder.DecodeException]. A cancellation is an `IllegalStateException` too, and passes through as
 * itself, so a cancelled caller sees its cancellation rather than a decode failure.
 */
internal inline fun <T> reportingCodecFailures(block: () -> T): T =
    try {
        block()
    } catch (e: CancellationException) {
        throw e
    } catch (e: IllegalStateException) {
        throw RecordingPcmDecoder.DecodeException("the decoder failed", e)
    }
