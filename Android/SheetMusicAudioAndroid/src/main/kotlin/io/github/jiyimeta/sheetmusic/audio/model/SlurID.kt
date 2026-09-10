package io.github.jiyimeta.sheetmusic.audio.model

/** Mirrors SheetMusicCore.SlurID. */
sealed class SlurID {
    /** A slur in the chord's (or rest's) spanners list; `ordinal` counts slurs only, hidden ones included. */
    data class Chord(val anchor: VoiceElementID, val ordinal: Int) : SlurID()
    /** A slur stored in its own spanner slot in `Voice.elements`. */
    data class Voice(val arg0: VoiceElementID) : SlurID()
}
