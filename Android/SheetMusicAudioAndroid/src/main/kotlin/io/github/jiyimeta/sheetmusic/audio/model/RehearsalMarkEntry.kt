package io.github.jiyimeta.sheetmusic.audio.model

/**
 * Mirrors `SheetMusicCore.RehearsalMarkEntry`: a rehearsal mark resolved onto the
 * notated timeline — its [text], the [fraction] (0..1) of the timeline it sits at
 * (the seek-bar position to align with), and the [cursor] to seek to when tapped.
 */
data class RehearsalMarkEntry(
    val text: String,
    val fraction: Double,
    val cursor: ScoreCursor,
)
