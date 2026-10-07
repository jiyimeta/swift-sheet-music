package io.github.jiyimeta.sheetmusic.audio.model

/**
 * What [io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine.replaceScore] did. Mirrors Apple's
 * `ScoreReplacementOutcome`.
 */
enum class ScoreReplacementOutcome {
    /**
     * The score was swapped in place: the synth with its loaded SoundFont presets, the metronome synth, the output
     * stream, the mixer channel state, rate, tuning, transpose and master gain were all kept.
     */
    SWAPPED_IN_PLACE,

    /** The engine fell back to a full `prepare` — nothing was prepared yet, or the channel layout changed. */
    FULLY_PREPARED,

    /** Nothing changed because an export was in flight. */
    IGNORED_WHILE_EXPORTING,
}
