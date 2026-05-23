package io.github.jiyimeta.sheetmusic.audio.model

/** Mirrors SheetMusicCore.ScoreCursor. */
sealed class ScoreCursor {
    data class Item(val arg0: ScoreItemID) : ScoreCursor()
    data class Beat(val measureIndex: Int, val tickInMeasure: Int) : ScoreCursor()
}
