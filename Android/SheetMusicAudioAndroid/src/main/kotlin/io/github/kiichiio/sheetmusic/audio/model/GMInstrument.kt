package io.github.kiichiio.sheetmusic.audio.model

import io.github.kiichiio.sheetmusic.audio.jni.SheetMusicAudioJNI
import io.github.kiichiio.sheetmusic.audio.serialization.GMInstrumentDecoder

/**
 * One General-MIDI Level 1 melodic program (0..127). Mirrors the
 * data carried by `SheetMusicAudioCore.GMInstrument` — Swift is the
 * source of truth for canonical names; Kotlin loads the list via the
 * `SheetMusicAudioJNI.nativeGMInstrumentList()` bridge on first
 * access. See the codec at `Sources/SheetMusicAndroidJNI/Audio/
 * GMInstrumentCodec.swift`.
 *
 * Constructed by [GMInstrumentDecoder], never by host code (other
 * than [__setForTests] in JVM unit tests).
 */
data class GMInstrument(
    val program: Int,
    val displayName: String,
    /**
     * Index into Swift's `GMInstrument.Family.allCases` (0..15). Each
     * family spans 8 consecutive programs. Currently informational —
     * a future picker UI can group rows by family using this.
     */
    val familyIndex: Int,
) {
    companion object {
        @Volatile private var cached: List<GMInstrument>? = null

        /**
         * All 128 GM patches in program order. Loaded once via JNI on
         * first access; cached for subsequent calls.
         *
         * In JVM unit tests where `libSheetMusicJNI.so` cannot be
         * loaded, use [__setForTests] before accessing.
         */
        val entries: List<GMInstrument>
            get() = cached ?: loadFromNative().also { cached = it }

        /**
         * Returns the GM patch for [program], or `null` if no entry
         * exists for that program number.
         */
        fun forProgram(program: Int): GMInstrument? =
            entries.firstOrNull { it.program == program }

        /**
         * Test seam: pre-populate the cache with a known list, or
         * pass `null` to reset (force the next access to re-load via
         * JNI). Intended for JVM unit tests only.
         */
        internal fun __setForTests(list: List<GMInstrument>?) {
            cached = list
        }

        private fun loadFromNative(): List<GMInstrument> {
            val bytes = SheetMusicAudioJNI.nativeGMInstrumentList()
            return GMInstrumentDecoder.decodeArray(bytes)
        }
    }
}
