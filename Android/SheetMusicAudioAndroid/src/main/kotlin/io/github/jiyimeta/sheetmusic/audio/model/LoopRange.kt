package io.github.jiyimeta.sheetmusic.audio.model

/**
 * Half-open tick range `[startTick, endTick)` the engine should
 * loop while playing. Mirrors `SheetMusicAudioCore.LoopRange`.
 */
data class LoopRange(val startTick: Long, val endTick: Long)
