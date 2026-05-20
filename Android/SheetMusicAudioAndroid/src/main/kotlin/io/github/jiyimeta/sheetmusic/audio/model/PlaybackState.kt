package io.github.jiyimeta.sheetmusic.audio.model

/** Mirrors SheetMusicAudioCore.PlaybackState. */
enum class PlaybackState {
    STOPPED,
    PREPARED,
    PLAYING,
    PAUSED,
    EXPORTING,
}
