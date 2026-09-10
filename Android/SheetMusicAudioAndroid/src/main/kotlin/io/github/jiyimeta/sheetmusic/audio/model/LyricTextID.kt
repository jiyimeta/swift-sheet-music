package io.github.jiyimeta.sheetmusic.audio.model

/** Mirrors SheetMusicCore.ScoreTextID.lyric. */
data class LyricTextID(
    val anchor: VoiceElementID,
    val verse: Int,
)
