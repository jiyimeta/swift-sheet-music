package io.github.jiyimeta.sheetmusic.audio.export

/**
 * The count an export plays ahead of its range: the one live playback plays from the same start.
 *
 * Built by the engine from the shared Swift — `CountInBeats` through `JniBridge.countIn` for the length, and
 * `JniBridge.renderCountInMetronomeMidi` for the clicks — so the file counts exactly what the user hears.
 */
internal class CountInExport(
    /**
     * The metronome's sequence with the count-in region in front and the body's clicks shifted behind it, as live
     * playback loads it for the same start.
     */
    val metronomeSmfBytes: ByteArray,
    /**
     * How long the pre-roll lasts on the sequence clock (rate 1): `CountInWire.totalSeconds`, which is
     * `CountInBeats.Result.preRollSeconds(division:)`. The render holds the score for this divided by the rate.
     */
    val preRollSeconds: Double,
)
