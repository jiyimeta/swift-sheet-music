package io.github.kiichiio.sheetmusic.audio.model

/** Mirrors SheetMusicCore.RestID. */
data class RestID(
    val staff: StaffAddress,
    val measureIndex: Int,
    val voiceIndex: Int,
    val elementIndex: Int,
)
