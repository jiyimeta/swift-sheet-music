package io.github.jiyimeta.sheetmusic.audio.model

/** Mirrors SheetMusicAudioCore.MixerChannel. */
data class MixerChannel(
    val staffIndex: Int,
    val displayName: String,
    val volume: Float = 1.0f,
    val isMuted: Boolean = false,
    val isSoloed: Boolean = false,
    val effectiveMute: Boolean = false,
)
