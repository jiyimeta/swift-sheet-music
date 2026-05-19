package io.github.kiichiio.sheetmusic.audio.model

/** Mirrors SheetMusicAudioCore.MetronomeBeat. */
data class MetronomeBeat(
    val tick: Long,
    val isDownbeat: Boolean,
)
