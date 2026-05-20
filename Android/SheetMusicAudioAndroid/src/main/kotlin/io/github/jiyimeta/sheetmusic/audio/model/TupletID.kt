package io.github.jiyimeta.sheetmusic.audio.model

/** Mirrors SheetMusicCore.TupletID. */
data class TupletID(
    val staff: StaffAddress,
    val measureIndex: Int,
    val voiceIndex: Int,
    val startElementIndex: Int,
)
