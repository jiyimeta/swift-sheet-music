package io.github.jiyimeta.sheetmusic.audio.model

/** Mirrors SheetMusicCore.ScoreItemID. */
sealed class ScoreItemID {
    data class Note(val id: NoteID) : ScoreItemID()
    data class Rest(val id: RestID) : ScoreItemID()
    data class Tuplet(val id: TupletID) : ScoreItemID()
    data class Clef(val anchor: ClefAnchor) : ScoreItemID()
}
