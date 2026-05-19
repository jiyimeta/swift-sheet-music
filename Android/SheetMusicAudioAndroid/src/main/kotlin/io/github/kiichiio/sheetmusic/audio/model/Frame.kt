package io.github.kiichiio.sheetmusic.audio.model

/** Mirrors the Frame type used in the Swift audio timeline. */
data class Frame(
    val tick: Long,
    val timeSeconds: Double,
    val cursor: ScoreCursor,
)
