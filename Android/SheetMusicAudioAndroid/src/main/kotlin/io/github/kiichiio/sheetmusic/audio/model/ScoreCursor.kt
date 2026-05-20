package io.github.kiichiio.sheetmusic.audio.model

/** Mirrors SheetMusicCore.ScoreCursor. */
sealed class ScoreCursor {
    data class Item(val item: ScoreItemID) : ScoreCursor()
    data class Beat(val measureIndex: Int, val tickInMeasure: Int) : ScoreCursor()
}
