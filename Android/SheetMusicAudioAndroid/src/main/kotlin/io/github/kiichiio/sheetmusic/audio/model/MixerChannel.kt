package io.github.kiichiio.sheetmusic.audio.model

/** Mirrors SheetMusicAudioCore.MixerChannel. */
data class MixerChannel(
    val staffIndex: Int,
    val displayName: String,
    val volume: Float = 1.0f,
    val isMuted: Boolean = false,
    val isSoloed: Boolean = false,
    val effectiveMute: Boolean = false,
    /**
     * GM program (0..127) driving this staff's sampler, or `null` for
     * drum staves and for staves whose program is not selectable from
     * UI. Mirrors Apple `MixerChannel.program: UInt8?`.
     */
    val program: Int? = null,
)
