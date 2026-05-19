package io.github.kiichiio.sheetmusic.audio.model

/** Mirrors SheetMusicCore.NoteID. */
data class NoteID(
    val staff: StaffAddress,
    val measureIndex: Int,
    val voiceIndex: Int,
    val elementIndex: Int,
    val noteIndexInChord: Int,
)
