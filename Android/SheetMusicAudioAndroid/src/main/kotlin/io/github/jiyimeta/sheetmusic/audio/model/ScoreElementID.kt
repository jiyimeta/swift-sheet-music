package io.github.jiyimeta.sheetmusic.audio.model

/** Mirrors SheetMusicCore.ScoreElementID. */
sealed class ScoreElementID {
    data class Dynamic(val arg0: VoiceElementID) : ScoreElementID()
    data class Fermata(val arg0: VoiceElementID) : ScoreElementID()
    data class Breath(val arg0: VoiceElementID) : ScoreElementID()
    data class Tempo(val arg0: VoiceElementID) : ScoreElementID()
    data class Spanner(val anchor: VoiceElementID, val kind: String) : ScoreElementID()
    data class KeySignature(val arg0: Int) : ScoreElementID()
    data class TimeSignature(val arg0: Int) : ScoreElementID()
    data class BarLine(val measureIndex: Int, val role: BarLineRole) : ScoreElementID()
    data class Articulation(val anchor: VoiceElementID, val kind: ScoreArticulationKind) : ScoreElementID()
    data class Tie(val start: NoteID, val end: NoteID) : ScoreElementID()
    data class Slur(val arg0: SlurID) : ScoreElementID()
    data class Jump(val staff: StaffAddress, val measureIndex: Int, val index: Int) : ScoreElementID()
    data class Marker(val staff: StaffAddress, val measureIndex: Int, val index: Int) : ScoreElementID()
}
