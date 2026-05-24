package io.github.jiyimeta.sheetmusic.audio.model

/**
 * Mirrors `SheetMusicAudioApple.AudioExportRange`.
 *
 * Describes which portion of a score should be rendered when exporting
 * to an audio file. Encoded over the JNI wire via
 * [io.github.jiyimeta.sheetmusic.audio.serialization.AudioExportRangeEncoder]
 * and decoded by the Swift bridge.
 */
sealed interface AudioExportRange {
    /** Render the entire score from the first measure to the final tick. */
    object Full : AudioExportRange

    /** Render the currently configured loop range. Implies a loop is set. */
    object CurrentLoop : AudioExportRange

    /** Render `[arg0, arg1]` (inclusive) bounded by two cursors. */
    data class Region(val arg0: ScoreCursor, val arg1: ScoreCursor) : AudioExportRange

    /**
     * Render from `arg0` through the end of the measure that contains `arg1`.
     * Used when the caller has a specific item as the right-hand bound.
     */
    data class RegionThroughEnd(val arg0: ScoreCursor, val arg1: ScoreItemID) : AudioExportRange
}
