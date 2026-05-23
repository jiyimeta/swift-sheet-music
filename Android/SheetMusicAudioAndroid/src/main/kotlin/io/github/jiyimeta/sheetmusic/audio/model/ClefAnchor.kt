package io.github.jiyimeta.sheetmusic.audio.model

/** Mirrors SheetMusicCore.ClefAnchor. */
sealed class ClefAnchor {
    data class Explicit(val arg0: VoiceElementID) : ClefAnchor()
    data class StaffDefault(val arg0: StaffAddress) : ClefAnchor()
}
