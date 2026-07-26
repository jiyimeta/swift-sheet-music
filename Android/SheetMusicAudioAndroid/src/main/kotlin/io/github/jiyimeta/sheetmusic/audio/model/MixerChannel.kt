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
     * Program (0..127) driving this staff's sampler, or `null` when the score
     * carries none. Mirrors Apple `MixerChannel.program: UInt8?`.
     *
     * Populated for drum staves too — there it is the percussion-bank (128) KIT
     * number, not a melodic patch. Use [isDrums] to tell the two apart; a host
     * that treats `program == null` as "this is a drum staff" is reading a
     * signal that no longer exists.
     */
    val program: Int? = null,
    /**
     * True when this staff plays on the percussion bank (the part's instrument
     * declares `useDrumset`). Mirrors the `isDrums` the staff-params wire has
     * always carried; surfaced here so a host can offer the drum-kit catalog
     * instead of the melodic GM one — and so it can tell "drums" apart from
     * "no program", which the old `program == null` encoding conflated.
     */
    val isDrums: Boolean = false,
)
