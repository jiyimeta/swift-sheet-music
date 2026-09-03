package io.github.jiyimeta.sheetmusic.audio.model

/** Mirrors SheetMusicCore.VoiceRef. */
data class VoiceRef(
    val staff: StaffAddress,
    val measureIndex: Int,
    val voiceIndex: Int,
)
