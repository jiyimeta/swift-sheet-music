package io.github.jiyimeta.sheetmusic.audio.export

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.ParcelFileDescriptor
import io.github.jiyimeta.sheetmusic.audio.AudioBackendException
import io.github.jiyimeta.sheetmusic.audio.model.AudioChannelCount
import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat
import io.github.jiyimeta.sheetmusic.audio.model.CompressedOptions
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal class Mp3MediaCodecEncoder(
    private val options: CompressedOptions,
    private val sampleRate: Int,
    fd: ParcelFileDescriptor,
) : AudioFileEncoder {
    private val codec: MediaCodec
    private val output: FileOutputStream
    private val mono = options.channels == AudioChannelCount.Mono
    private var accumulatedFrames: Long = 0
    private var finished = false
    private val bufferInfo = MediaCodec.BufferInfo()

    init {
        val format = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_MPEG, options.sampleRate, options.channels.rawValue,
        )
        format.setInteger(MediaFormat.KEY_BIT_RATE, options.bitRate)
        val codecName = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(format)
            ?: throw AudioBackendException.FormatUnsupportedOnThisOS(AudioFileFormat.Mp3(options))
        codec = MediaCodec.createByCodecName(codecName)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
        output = FileOutputStream(fd.fileDescriptor)
    }

    override fun appendPcmFloat(left: FloatArray, right: FloatArray, frames: Int) {
        val tmp = ShortArray(frames * options.channels.rawValue)
        PcmSampleConversion.floatToInt16Interleaved(left, right, frames, mono, tmp)
        val bytes = ByteArray(tmp.size * 2)
        ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().put(tmp)
        feedEncoder(bytes, accumulatedFrames * 1_000_000L / sampleRate, false)
        accumulatedFrames += frames
        drainEncoder(false)
    }

    private fun feedEncoder(payload: ByteArray, ptsUs: Long, endOfStream: Boolean) {
        while (true) {
            val inIdx = codec.dequeueInputBuffer(10_000)
            if (inIdx < 0) continue
            val buf = codec.getInputBuffer(inIdx) ?: return
            buf.clear(); buf.put(payload)
            codec.queueInputBuffer(
                inIdx, 0, payload.size, ptsUs,
                if (endOfStream) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0,
            )
            return
        }
    }

    private fun drainEncoder(endOfStream: Boolean) {
        while (true) {
            val outIdx = codec.dequeueOutputBuffer(bufferInfo, if (endOfStream) 10_000 else 0)
            when {
                outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!endOfStream) return
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> { /* MP3 has no container — ignore */ }
                outIdx >= 0 -> {
                    val buf = codec.getOutputBuffer(outIdx)
                    if (buf == null) {
                        codec.releaseOutputBuffer(outIdx, false)
                        continue
                    }
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                        codec.releaseOutputBuffer(outIdx, false)
                        continue
                    }
                    if (bufferInfo.size > 0) {
                        val out = ByteArray(bufferInfo.size)
                        buf.position(bufferInfo.offset)
                        buf.get(out, 0, bufferInfo.size)
                        output.write(out)
                    }
                    codec.releaseOutputBuffer(outIdx, false)
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
                }
            }
        }
    }

    override fun finish() {
        if (finished) return
        feedEncoder(ByteArray(0), accumulatedFrames * 1_000_000L / sampleRate, true)
        drainEncoder(true)
        output.flush()
        try { output.fd.sync() } catch (_: Throwable) {}
        codec.stop(); codec.release()
        finished = true
    }

    override fun close() {
        try { if (!finished) codec.stop() } catch (_: Throwable) {}
        try { codec.release() } catch (_: Throwable) {}
        try { output.close() } catch (_: Throwable) {}
    }
}
