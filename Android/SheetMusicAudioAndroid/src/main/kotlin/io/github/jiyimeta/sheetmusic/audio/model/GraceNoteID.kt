package io.github.jiyimeta.sheetmusic.audio.model

/**
 * Mirrors SheetMusicCore.GraceNoteID: one notehead of a grace chord, addressed through the chord it ornaments.
 * [isAfter] carries `GraceNoteID.Side` — `false` for a grace before its parent, `true` for one after it.
 */
data class GraceNoteID(
    val parent: VoiceElementID,
    val isAfter: Boolean,
    val graceIndex: Int,
    val noteIndexInGraceChord: Int,
)
