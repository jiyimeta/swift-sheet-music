package io.github.kiichiio.sheetmusic.audio.model

/** Mirrors SheetMusicAudioCore.PlaybackState. */
enum class PlaybackState {
    STOPPED,
    PREPARED,
    PLAYING,
    PAUSED,
    EXPORTING,
}
