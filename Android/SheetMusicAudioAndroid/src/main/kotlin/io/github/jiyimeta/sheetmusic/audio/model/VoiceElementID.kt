package io.github.jiyimeta.sheetmusic.audio.model

/** Mirrors SheetMusicCore.VoiceElementID. */
data class VoiceElementID(
    val staff: StaffAddress,
    val measureIndex: Int,
    val voiceIndex: Int,
    val elementIndex: Int,
)
