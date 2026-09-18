package io.github.jiyimeta.sheetmusic.audio.model

/** Mirrors SheetMusicCore.ClefAnchor. */
sealed class ClefAnchor {
    data class Explicit(val arg0: VoiceElementID) : ClefAnchor()
    data class StaffDefault(val arg0: StaffAddress) : ClefAnchor()

    /** A continuation system's head clef, named by the staff and the bar it is drawn at the head of. */
    data class Restatement(val staff: StaffAddress, val measureIndex: Int) : ClefAnchor()
}
