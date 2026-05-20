package io.github.jiyimeta.sheetmusic.audio.export

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.ParcelFileDescriptor
import io.github.jiyimeta.sheetmusic.audio.model.AudioChannelCount
import io.github.jiyimeta.sheetmusic.audio.model.CompressedOptions
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * AAC LC encoder writing an M4A (MP4 audio) container via [MediaCodec] +
 * [MediaMuxer]. Float32 stereo PCM is converted to int16 little-endian for
 * MediaCodec input.
 *
 * Lifecycle: codec started in init → fed in [appendPcmFloat] → drained on
 * each append → EOS-flushed in [finish] → muxer + codec released.
 */
internal class AacM4aEncoder(
    private val options: CompressedOptions,
    private val sampleRate: Int,
    fd: ParcelFileDescriptor,
) : AudioFileEncoder {
    private val codec: MediaCodec
    private val muxer: MediaMuxer
    private val mono = options.channels == AudioChannelCount.Mono
    private var trackIndex: Int = -1
    private var muxerStarted = false
    private var accumulatedFrames: Long = 0
    private var finished = false
    private val bufferInfo = MediaCodec.BufferInfo()

    init {
        val format = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_AAC, options.sampleRate, options.channels.rawValue,
        )
        format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
        format.setInteger(MediaFormat.KEY_BIT_RATE, options.bitRate)
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 8192 * 2)
        codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
        muxer = MediaMuxer(fd.fileDescriptor, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    }

    override fun appendPcmFloat(left: FloatArray, right: FloatArray, frames: Int) {
        val tmp = ShortArray(frames * options.channels.rawValue)
        PcmSampleConversion.floatToInt16Interleaved(left, right, frames, mono, tmp)
        val bytes = ByteArray(tmp.size * 2)
        ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().put(tmp)
        // Drain first: free up input buffers that the previous call queued
        // but the codec hasn't released yet. Without this, dequeueInputBuffer
        // returns -1 forever once the codec is saturated.
        drainEncoder(false)
        feedEncoder(bytes, accumulatedFrames * 1_000_000L / sampleRate, false)
        accumulatedFrames += frames
        drainEncoder(false)
    }

    private fun feedEncoder(payload: ByteArray, ptsUs: Long, endOfStream: Boolean) {
        while (true) {
            val inputIndex = codec.dequeueInputBuffer(10_000)
            if (inputIndex < 0) {
                // Codec has no free input buffers: drain outputs to release them.
                drainEncoder(endOfStream)
                continue
            }
            val inputBuffer = codec.getInputBuffer(inputIndex) ?: return
            inputBuffer.clear()
            inputBuffer.put(payload)
            val flags = if (endOfStream) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0
            codec.queueInputBuffer(inputIndex, 0, payload.size, ptsUs, flags)
            return
        }
    }

    private fun drainEncoder(endOfStream: Boolean) {
        while (true) {
            val outIndex = codec.dequeueOutputBuffer(bufferInfo, if (endOfStream) 10_000 else 0)
            when {
                outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) return
                }
                outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    trackIndex = muxer.addTrack(codec.outputFormat)
                    muxer.start()
                    muxerStarted = true
                }
                outIndex >= 0 -> {
                    val outBuffer = codec.getOutputBuffer(outIndex) ?: continue
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                        codec.releaseOutputBuffer(outIndex, false)
                        continue
                    }
                    if (muxerStarted && bufferInfo.size > 0) {
                        outBuffer.position(bufferInfo.offset)
                        outBuffer.limit(bufferInfo.offset + bufferInfo.size)
                        muxer.writeSampleData(trackIndex, outBuffer, bufferInfo)
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
                }
            }
        }
    }

    override fun finish() {
        if (finished) return
        feedEncoder(ByteArray(0), accumulatedFrames * 1_000_000L / sampleRate, true)
        drainEncoder(true)
        if (muxerStarted) muxer.stop()
        muxer.release()
        codec.stop()
        codec.release()
        finished = true
    }

    override fun close() {
        if (!finished) {
            try { codec.stop() } catch (_: Throwable) {}
            try { codec.release() } catch (_: Throwable) {}
            try { muxer.release() } catch (_: Throwable) {}
        }
    }
}
