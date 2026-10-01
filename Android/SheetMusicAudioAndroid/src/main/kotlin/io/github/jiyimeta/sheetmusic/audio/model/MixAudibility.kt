package io.github.jiyimeta.sheetmusic.audio.model

/**
 * The mixer's mute / solo rule — the ONE place this module decides whether a strip sounds. Live playback
 * (`AndroidPlaybackEngine`, through [MixerChannel.effectiveMute]) and audio export (`AudioExporter`, the CC 7 it
 * renders each strip at) both read it, so a strip the user hears silent is silent in the exported file.
 *
 * Mirrors `Sources/SheetMusicAudioCore/MixerChannel+Audibility.swift` — `Collection<MixerChannel>.isSoloing` and
 * `MixerChannel.isSilenced(soloing:)` — which the Apple engine reads for playback and, through
 * `PlaybackEngine.exportVolumeCC7(of:soloing:)`, for export:
 * - mute wins: a muted strip is silent whatever its solo button says;
 * - while any strip is soloed, a strip that is not soloed is silent;
 * - a strip both muted and soloed is silent, yet it still engages solo, so the strips that are not soloed go
 *   silent with it.
 *
 * Every [MixerChannel] is an instrument strip. The metronome is not one — it has its own `MetronomeMixer`, gated by
 * its own enable flag — which is Apple's "off the solo bus" (`MixerChannel.isSoloable == false`) by construction:
 * soloing a part to practise against the click does not take the click with it.
 */
internal object MixAudibility {
    /** Whether the solo bus is engaged — at least one strip is soloed, muted or not. */
    fun isSoloing(strips: Collection<MixerChannel>): Boolean = strips.any { it.isSoloed }

    /** Whether [strip] is silent: muted, or [soloing] is engaged and [strip] is not soloed. */
    fun isSilenced(strip: MixerChannel, soloing: Boolean): Boolean =
        strip.isMuted || (soloing && !strip.isSoloed)
}
