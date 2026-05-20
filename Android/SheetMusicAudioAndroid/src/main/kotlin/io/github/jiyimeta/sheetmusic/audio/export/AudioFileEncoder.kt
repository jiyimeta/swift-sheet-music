package io.github.jiyimeta.sheetmusic.audio.export

/**
 * Common contract for audio-file encoders (WAV / AIFF / M4A / MP3).
 *
 * Encoders accept stereo float32 PCM frames via [appendPcmFloat]. Mono
 * encoders consume only the [left] channel and ignore [right]. After all
 * frames have been appended, callers MUST invoke [finish] to flush any
 * trailing buffers and back-fill headers / finalize muxers. [close]
 * releases the underlying file descriptor.
 *
 * A factory `companion object create(...)` that dispatches on
 * [io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat] will be
 * added once all four concrete encoders exist.
 */
internal interface AudioFileEncoder : AutoCloseable {
    /**
     * Append [frames] frames of stereo float32 audio to the encoder.
     * For mono encoders, only [left] is consumed; [right] is ignored.
     */
    fun appendPcmFloat(left: FloatArray, right: FloatArray, frames: Int)

    /** Finalize headers / muxer. MUST be called before [close] on the happy path. */
    fun finish()
}
