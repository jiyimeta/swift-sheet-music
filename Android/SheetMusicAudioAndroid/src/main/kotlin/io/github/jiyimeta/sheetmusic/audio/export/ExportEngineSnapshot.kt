package io.github.jiyimeta.sheetmusic.audio.export

import io.github.jiyimeta.sheetmusic.audio.model.MetronomeBeat
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
    val metronomeBeats: List<MetronomeBeat>,
    val rate: Float,
    /** Resolved metronome click (GeneratedSf2 / ExistingUri / DefaultGm). */
    val metronomeResolution: AndroidMetronomeClickResolver.Resolution,
)
