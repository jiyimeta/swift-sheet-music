package io.github.jiyimeta.sheetmusic.audio.model

/** Mirrors SheetMusicCore.ClefAnchor. */
sealed class ClefAnchor {
    data class Explicit(val voiceElementID: VoiceElementID) : ClefAnchor()
    data class StaffDefault(val staff: StaffAddress) : ClefAnchor()
}
