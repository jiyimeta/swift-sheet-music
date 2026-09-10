package io.github.jiyimeta.sheetmusic.audio.model

/**
 * Mirrors SheetMusicCore.ScoreTextID.staffText.
 * The wire represents Swift's TextStyleType as isSystemText: Boolean.
 */
data class StaffTextID(
    val anchor: VoiceElementID,
    val isSystemText: Boolean,
)
