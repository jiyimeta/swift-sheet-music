package io.github.jiyimeta.sheetmusic.audio.model

/** Mirrors SheetMusicAudioCore.PcmBitDepth. */
enum class PcmBitDepth { Int16, Int24, Int32, Float32 }

/** Mirrors SheetMusicAudioCore.AudioChannelCount; rawValue is the channel count. */
enum class AudioChannelCount(val rawValue: Int) {
    Mono(1),
    Stereo(2),
}

/** Mirrors SheetMusicAudioCore.PcmOptions. */
data class PcmOptions(
    val sampleRate: Int = 44100,
    val bitDepth: PcmBitDepth = PcmBitDepth.Int16,
    val channels: AudioChannelCount = AudioChannelCount.Stereo,
)

/** Mirrors SheetMusicAudioCore.CompressedOptions. */
data class CompressedOptions(
    val sampleRate: Int = 44100,
    val bitRate: Int = 192_000,
    val channels: AudioChannelCount = AudioChannelCount.Stereo,
)

/**
 * Mirrors SheetMusicAudioCore.AudioFileFormat. Each variant carries the
 * options appropriate to its container — PCM formats (Wav, Aiff) take
 * [PcmOptions], compressed formats (M4a, Mp3) take [CompressedOptions].
 */
sealed interface AudioFileFormat {
    data class Wav(val options: PcmOptions = PcmOptions()) : AudioFileFormat
    data class Aiff(val options: PcmOptions = PcmOptions()) : AudioFileFormat
    data class M4a(val options: CompressedOptions = CompressedOptions()) : AudioFileFormat
    data class Mp3(val options: CompressedOptions = CompressedOptions()) : AudioFileFormat
}
