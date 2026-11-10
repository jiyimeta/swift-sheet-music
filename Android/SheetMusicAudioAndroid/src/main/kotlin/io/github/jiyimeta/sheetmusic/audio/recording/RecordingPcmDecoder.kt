package io.github.jiyimeta.sheetmusic.audio.recording

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer

/**
 * Decodes a recording once into the PCM cache file [io.github.jiyimeta.sheetmusic.audio.model.RecordingTrack.pcmPath]
 * names — Android's counterpart of Apple's `RecordingPCMCache.prepare`. MediaExtractor + MediaCodec decode anything
 * the platform reads (AAC/M4A, MP3, FLAC, Ogg, WAV …) to 16-bit PCM at the source's own sample rate, and the Swift
 * writer ([RecordingPcmWriterCalls]) writes `RecordingPCMCacheFormat`, `<cacheKey>-<Hz>.pcm` in [directory], header
 * last and renamed into place. The engine reads it at any rate: a track is resampled as it is read.
 *
 * An existing valid file for the key and rate is reused untouched. The key must change when the source's content
 * does (Apple keys its files by content too).
 */
class RecordingPcmDecoder internal constructor(
    private val directory: File,
    private val writer: RecordingPcmWriterCalls,
) {
    /** A decoder writing its cache files into [directory], which it creates if needed. */
    constructor(directory: File) : this(directory, RecordingPcmNative)

    /** Why a recording could not be decoded. */
    class DecodeException(message: String, cause: Throwable? = null) : IOException(message, cause)

    /**
     * Decodes [source] — a `content:` or `file:` URI — to `<cacheKey>-<Hz>.pcm` and returns that file's path, reusing
     * one already there. Runs on [Dispatchers.IO]; cancelling the caller stops it between buffers and removes the
     * partial file, and the caller sees its cancellation rather than a [DecodeException].
     *
     * @throws DecodeException when the source has no audio track, the platform cannot decode it, it decodes to
     *   nothing, or the file cannot be written.
     */
    suspend fun prepare(context: Context, source: Uri, cacheKey: String): String = withContext(Dispatchers.IO) {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(context, source, null)
            decode(extractor, cacheKey)
        } catch (e: IOException) {
            throw e as? DecodeException ?: DecodeException("cannot read $source", e)
        } finally {
            extractor.release()
        }
    }

    /** [prepare] for a file on disk. */
    suspend fun prepare(sourcePath: String, cacheKey: String): String = withContext(Dispatchers.IO) {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(sourcePath)
            decode(extractor, cacheKey)
        } catch (e: IOException) {
            throw e as? DecodeException ?: DecodeException("cannot read $sourcePath", e)
        } finally {
            extractor.release()
        }
    }

    private suspend fun decode(extractor: MediaExtractor, cacheKey: String): String {
        val track = (0 until extractor.trackCount).firstOrNull { index ->
            extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
        } ?: throw DecodeException("no audio track")
        val format = extractor.getTrackFormat(track)
        val mime = format.getString(MediaFormat.KEY_MIME) ?: throw DecodeException("no audio track")
        val sourceRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        directory.mkdirs()
        val dir = directory.absolutePath
        writer.existing(dir, cacheKey, sourceRate.toDouble()).takeIf { it.isNotEmpty() }?.let { return it }

        extractor.selectTrack(track)
        val codec = try {
            MediaCodec.createDecoderByType(mime)
        } catch (e: Exception) {
            throw DecodeException("no decoder for $mime", e)
        }
        try {
            return reportingCodecFailures {
                codec.configure(format, null, null, 0)
                codec.start()
                decodeToCache(
                    MediaCodecDecode(codec, extractor),
                    writer,
                    dir,
                    cacheKey,
                    sourceRate,
                    sourceChannels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT),
                )
            }
        } finally {
            try { codec.stop() } catch (_: Throwable) {}
            codec.release()
        }
    }
}

/** [DecodeCodec] over a started [codec] reading [extractor]'s selected track. */
private class MediaCodecDecode(
    private val codec: MediaCodec,
    private val extractor: MediaExtractor,
) : DecodeCodec {
    private val bufferInfo = MediaCodec.BufferInfo()

    override fun dequeueInputBuffer(timeoutMicros: Long): Int = codec.dequeueInputBuffer(timeoutMicros)

    override fun queueInput(index: Int): Boolean {
        val buffer = codec.getInputBuffer(index) ?: throw RecordingPcmDecoder.DecodeException("no input buffer")
        val size = extractor.readSampleData(buffer, 0)
        if (size < 0) {
            codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            return false
        }
        codec.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
        extractor.advance()
        return true
    }

    override fun dequeueOutputBuffer(info: DecodedBufferInfo, timeoutMicros: Long): Int {
        val index = codec.dequeueOutputBuffer(bufferInfo, timeoutMicros)
        if (index >= 0) {
            info.offset = bufferInfo.offset
            info.size = bufferInfo.size
            info.endOfStream = bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
        }
        return index
    }

    override fun outputBuffer(index: Int): ByteBuffer? = codec.getOutputBuffer(index)

    override fun releaseOutputBuffer(index: Int) = codec.releaseOutputBuffer(index, false)

    override fun outputFormat(): DecodedFormat {
        val out = codec.outputFormat
        return DecodedFormat(
            channels = out.getInteger(MediaFormat.KEY_CHANNEL_COUNT),
            sampleRate = out.getInteger(MediaFormat.KEY_SAMPLE_RATE),
            floatSamples = out.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                out.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT,
        )
    }
}

/**
 * A valid cache file for [cacheKey] at the decoder's [outputRate] once its output format is known, to be returned
 * instead of decoding: null when that rate is the container's [sourceRate], already looked up before the decode, or
 * while a file is being [writing] (a format that changes mid-stream). Apart so a JVM test can pin it.
 */
internal fun RecordingPcmWriterCalls.existingAfterFormatChange(
    directory: String,
    cacheKey: String,
    sourceRate: Int,
    outputRate: Int,
    writing: Boolean,
): String? {
    if (writing || outputRate == sourceRate) return null
    return existing(directory, cacheKey, outputRate.toDouble()).takeIf { it.isNotEmpty() }
}

/** The sample conversions a decoded buffer goes through before the writer, apart so a JVM test can pin them. */
internal object PcmConversion {
    /**
     * Float samples to Int16, rounded half away from zero (Swift's `rounded()`) and clamped to ±32767 — the conversion
     * Apple's `RecordingPCMCache` makes.
     */
    fun int16(samples: FloatArray): ShortArray =
        ShortArray(samples.size) { index ->
            val scaled = samples[index] * 32767f
            val rounded = if (scaled < 0f) -((-scaled) + 0.5f).toInt() else (scaled + 0.5f).toInt()
            rounded.coerceIn(-32767, 32767).toShort()
        }

    /**
     * [frames] frames of [channels] interleaved samples, as the writer takes them: mono and stereo as they are (the
     * writer duplicates mono onto both channels), and more channels cut to their first two, front left and right.
     * Returns the samples and their channel count; [scratch] is reused when it is big enough.
     */
    fun atMostStereo(samples: ShortArray, frames: Int, channels: Int, scratch: ShortArray): Pair<ShortArray, Int> {
        if (channels <= 2) return samples to channels.coerceAtLeast(1)
        val out = if (scratch.size >= frames * 2) scratch else ShortArray(frames * 2)
        for (frame in 0 until frames) {
            out[2 * frame] = samples[frame * channels]
            out[2 * frame + 1] = samples[frame * channels + 1]
        }
        return out to 2
    }
}
