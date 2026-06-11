package io.github.jiyimeta.sheetmusic.audio.model

/** Mirrors SheetMusicAudioCore.MixerChannel. */
data class MixerChannel(
    val staffIndex: Int,
    val displayName: String,
    val volume: Float = 1.0f,
    /**
     * Score-authored initial volume (MIDI CC7 → 0..1), the slider's reset
     * target and tick position. Independent of any user override, so the UI can
     * keep offering "reset to the score's volume" after the user has dragged the
     * slider. Mirrors iOS `PlaybackMixerModel.defaultVolume(for:)`. Falls back to
     * the GM default of 100/127 ≈ 0.787 when the score carries no explicit
     * channel volume (the wire default of `StaffParams.channelVolume`).
     */
    val defaultVolume: Float = 1.0f,
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
