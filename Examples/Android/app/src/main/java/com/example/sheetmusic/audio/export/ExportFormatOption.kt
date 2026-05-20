package com.example.sheetmusic.audio.export

import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat
import io.github.jiyimeta.sheetmusic.audio.model.CompressedOptions
import io.github.jiyimeta.sheetmusic.audio.model.PcmOptions

/**
 * UI-side enum for the format picker. Maps each visible option to its
 * SAF MIME type, file extension, and the corresponding
 * [AudioFileFormat] value the engine consumes.
 */
enum class ExportFormatOption(
    val displayName: String,
    val mime: String,
    val extension: String,
) {
    Wav("WAV", "audio/wav", "wav"),
    Aiff("AIFF", "audio/aiff", "aiff"),
    M4a("M4A (AAC)", "audio/mp4", "m4a"),
    Mp3("MP3", "audio/mpeg", "mp3");

    fun toAudioFileFormat(): AudioFileFormat = when (this) {
        Wav -> AudioFileFormat.Wav(PcmOptions())
        Aiff -> AudioFileFormat.Aiff(PcmOptions())
        M4a -> AudioFileFormat.M4a(CompressedOptions())
        Mp3 -> AudioFileFormat.Mp3(CompressedOptions())
    }
}
