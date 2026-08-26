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
    /**
     * Live A4 calibration in cents off 440, from `setMasterTuning`.
     *
     * The offline render builds its own synth, so it starts at concert pitch and knows nothing about
     * the live engine's tuning unless it is carried here. Without it a calibrated score exported at
     * A4 = 442 comes back at 440.
     */
    val masterTuningCents: Double = 0.0,
    /**
     * Live whole-score transpose in semitones, from `setTranspose`.
     *
     * Transposed playback is a tuning shift, never a re-render, so the rendered SMF the exporter
     * loads carries the AUTHORED pitches. Dropping this field is why a transposed score used to
     * export in its original key on every device.
     */
    val transposeSemitones: Int = 0,
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
            metronomeResolution == other.metronomeResolution &&
            masterTuningCents == other.masterTuningCents &&
            transposeSemitones == other.transposeSemitones
    }

    override fun hashCode(): Int {
        var result = mixerChannels.hashCode()
        result = 31 * result + metronomeEnabled.hashCode()
        result = 31 * result + metronomeVolume.hashCode()
        result = 31 * result + metronomeSmfBytes.contentHashCode()
        result = 31 * result + rate.hashCode()
        result = 31 * result + metronomeResolution.hashCode()
        result = 31 * result + masterTuningCents.hashCode()
        result = 31 * result + transposeSemitones
        return result
    }
}
