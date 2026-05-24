package io.github.jiyimeta.sheetmusic.audio.model

/** Mirrors SheetMusicCore.ScoreItemID. */
sealed class ScoreItemID {
    data class Note(val arg0: NoteID) : ScoreItemID()
    data class Rest(val arg0: RestID) : ScoreItemID()
    data class Tuplet(val arg0: TupletID) : ScoreItemID()
    data class Clef(val arg0: ClefAnchor) : ScoreItemID()
}
