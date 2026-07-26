package io.github.jiyimeta.sheetmusic.audio.export

import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel
import io.github.jiyimeta.sheetmusic.audio.synth.AndroidMetronomeClickResolver

/**
 * Snapshot of mutable engine state captured at the top of an export call.
 * The export pipeline reads this; the live engine is not touched.
 */
internal data class ExportEngineSnapshot(
    val mixerChannels: List<MixerChannel>,
    val metronomeEnabled: Boolean,
    val metronomeVolume: Float,
    /**
     * The metronome's own SMF (tempo map + click track), played on a second player during the render —
     * the same transport-scheduled clicks live playback uses. Empty when the score has no beats.
     */
    val metronomeSmfBytes: ByteArray,
    val rate: Float,
    /** Resolved metronome click (GeneratedSf2 / ExistingUri / DefaultGm). */
    val metronomeResolution: AndroidMetronomeClickResolver.Resolution,
) {
    // `metronomeSmfBytes` makes the generated equals/hashCode identity-based; compare by content so the
    // data-class semantics hold for tests that assert on a captured snapshot.
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is ExportEngineSnapshot) return false
        return mixerChannels == other.mixerChannels &&
            metronomeEnabled == other.metronomeEnabled &&
            metronomeVolume == other.metronomeVolume &&
            metronomeSmfBytes.contentEquals(other.metronomeSmfBytes) &&
            rate == other.rate &&
            metronomeResolution == other.metronomeResolution
    }

    override fun hashCode(): Int {
        var result = mixerChannels.hashCode()
        result = 31 * result + metronomeEnabled.hashCode()
        result = 31 * result + metronomeVolume.hashCode()
        result = 31 * result + metronomeSmfBytes.contentHashCode()
        result = 31 * result + rate.hashCode()
        result = 31 * result + metronomeResolution.hashCode()
        return result
    }
}
