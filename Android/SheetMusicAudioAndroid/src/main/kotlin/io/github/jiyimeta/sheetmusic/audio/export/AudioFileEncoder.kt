package io.github.jiyimeta.sheetmusic.audio.export

import android.os.ParcelFileDescriptor
import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat

internal interface AudioFileEncoder : AutoCloseable {
    /**
     * Append [frames] frames of stereo float32 audio to the encoder.
     * For mono encoders, only [left] is consumed; [right] is ignored.
     */
    fun appendPcmFloat(left: FloatArray, right: FloatArray, frames: Int)

    /** Finalize headers / muxer. MUST be called before [close] on the happy path. */
    fun finish()

    companion object {
        /**
         * Dispatch on [format] to construct a concrete encoder bound to [fd].
         * WAV / AIFF take the raw [java.io.FileDescriptor] (extracted from [fd])
         * because they back-fill header sizes via [java.nio.channels.FileChannel].
         * M4A / MP3 take the [ParcelFileDescriptor] directly — MediaMuxer and
         * MediaCodec consume the [android.os.ParcelFileDescriptor] / its underlying
         * file descriptor differently.
         */
        fun create(
            format: AudioFileFormat,
            sampleRate: Int,
            fd: ParcelFileDescriptor,
        ): AudioFileEncoder = when (format) {
            is AudioFileFormat.Wav -> WavPcmEncoder(format.options, sampleRate, fd.fileDescriptor)
            is AudioFileFormat.Aiff -> AiffPcmEncoder(format.options, sampleRate, fd.fileDescriptor)
            is AudioFileFormat.M4a -> AacM4aEncoder(format.options, sampleRate, fd)
            is AudioFileFormat.Mp3 -> Mp3MediaCodecEncoder(format.options, sampleRate, fd)
        }
    }
}
