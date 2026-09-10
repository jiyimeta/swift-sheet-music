package io.github.jiyimeta.sheetmusic.audio.model

/** Mirrors SheetMusicCore.ScoreTextID. */
sealed class ScoreTextID {
    data class Lyric(val arg0: LyricTextID) : ScoreTextID()
    data class StaffText(val arg0: StaffTextID) : ScoreTextID()
    data class Harmony(val arg0: VoiceElementID) : ScoreTextID()
    data class RehearsalMark(val arg0: Int) : ScoreTextID()
}
