package io.github.jiyimeta.sheetmusic.audio.model

/** Mirrors SheetMusicCore.PartNameForm. */
sealed class PartNameForm {
    object Long : PartNameForm()
    object Short : PartNameForm()
}
