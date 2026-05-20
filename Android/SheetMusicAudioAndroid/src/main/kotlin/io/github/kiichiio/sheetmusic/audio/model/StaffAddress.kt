package io.github.kiichiio.sheetmusic.audio.model

/** Mirrors SheetMusicCore.StaffAddress. */
data class StaffAddress(
    val partIndex: Int,
    val staffIndexInPart: Int,
)
