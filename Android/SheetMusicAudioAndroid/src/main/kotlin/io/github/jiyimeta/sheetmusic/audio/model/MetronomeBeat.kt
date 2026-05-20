package io.github.jiyimeta.sheetmusic.audio.model

/** Mirrors SheetMusicAudioCore.MetronomeBeat. */
data class MetronomeBeat(
    val tick: Long,
    val isDownbeat: Boolean,
)
