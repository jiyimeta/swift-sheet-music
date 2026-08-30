package io.github.jiyimeta.sheetmusic.audio.model

/** One MIDI Control-Change message: a controller number and its 7-bit value. */
data class MidiControlChange(val controller: Int, val value: Int)
