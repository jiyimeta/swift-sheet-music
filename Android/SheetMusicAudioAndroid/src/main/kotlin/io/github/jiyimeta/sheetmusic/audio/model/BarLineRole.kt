package io.github.jiyimeta.sheetmusic.audio.model

/** Mirrors SheetMusicCore.BarLineRole. */
sealed class BarLineRole {
    object Explicit : BarLineRole()
    object StartRepeat : BarLineRole()
    object Trailing : BarLineRole()
}
