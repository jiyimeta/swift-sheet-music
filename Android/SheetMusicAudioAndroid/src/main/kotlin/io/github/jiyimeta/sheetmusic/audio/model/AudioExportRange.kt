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

    /** Render `[from, to]` (inclusive) bounded by two cursors. */
    data class Region(val from: ScoreCursor, val to: ScoreCursor) : AudioExportRange

    /**
     * Render from `from` through the end of the measure that contains `last`.
     * Used when the caller has a specific item as the right-hand bound.
     */
    data class RegionThroughEnd(val from: ScoreCursor, val last: ScoreItemID) : AudioExportRange
}
