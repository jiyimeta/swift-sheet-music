package io.github.jiyimeta.sheetmusic.audio.jni

import org.swift.swiftkit.core.SwiftMemoryManagement
import io.github.jiyimeta.sheetmusic.swiftjava.Data as SwiftData
import io.github.jiyimeta.sheetmusic.swiftjava.SheetMusicAndroidJNI as SwiftJavaJNI

internal object SheetMusicAudioJNI {
    // All entry points have been migrated to swift-java. The Kotlin
    // wrappers below delegate through the generated SheetMusicAndroidJNI
    // class (aliased SwiftJavaJNI), passing/receiving `Data` through the
    // default auto-arena.

    fun nativeGMInstrumentList(): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeGMInstrumentList(arena).toByteArray()
    }

    fun nativePitchAndStaffOfNote(scoreHandle: Long, noteIdBytes: ByteArray): Long {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativePitchAndStaffOfNote(
            scoreHandle,
            SwiftData.fromByteArray(noteIdBytes, arena),
        )
    }

    fun nativeItemEndTick(scoreHandle: Long, idBytes: ByteArray): Long {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeItemEndTick(
            scoreHandle,
            SwiftData.fromByteArray(idBytes, arena),
        )
    }

    fun nativeRenderMidi(scoreHandle: Long): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeRenderMidi(scoreHandle, arena).toByteArray()
    }

    fun nativeRenderMetronomeMidi(scoreHandle: Long): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeRenderMetronomeMidi(scoreHandle, arena).toByteArray()
    }

    fun nativeRenderCountInMetronomeMidi(
        scoreHandle: Long,
        cursorBytes: ByteArray,
        baseTick: Long,
    ): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeRenderCountInMetronomeMidi(
            scoreHandle,
            SwiftData.fromByteArray(cursorBytes, arena),
            baseTick,
            arena,
        ).toByteArray()
    }

    fun nativeTimelineSummary(scoreHandle: Long): LongArray =
        SwiftJavaJNI.nativeTimelineSummary(scoreHandle)

    fun nativeFrameAtTick(scoreHandle: Long, tick: Long): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeFrameAtTick(scoreHandle, tick, arena).toByteArray()
    }

    fun nativeFrameForCursor(scoreHandle: Long, cursorBytes: ByteArray): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeFrameForCursor(
            scoreHandle,
            SwiftData.fromByteArray(cursorBytes, arena),
            arena,
        ).toByteArray()
    }

    /**
     * Count-in ("pre-roll") schedule for playback starting at [fromCursorBytes], from the shared
     * `CountInBeats` — the same computation the Apple engine's pre-roll sequence is built from. Click
     * offsets arrive already converted to SECONDS so no tempo math is redone here. Decodes to
     * `CountInWire`; an empty schedule (`totalSeconds == 0`) means "no count-in — start immediately".
     */
    fun nativeCountIn(scoreHandle: Long, fromCursorBytes: ByteArray): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeCountIn(
            scoreHandle,
            SwiftData.fromByteArray(fromCursorBytes, arena),
            arena,
        ).toByteArray()
    }

    fun nativeStaffParams(scoreHandle: Long): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeStaffParams(scoreHandle, arena).toByteArray()
    }

    fun nativeEarliestOf(scoreHandle: Long, idsBytes: ByteArray): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeEarliestOf(
            scoreHandle,
            SwiftData.fromByteArray(idsBytes, arena),
            arena,
        ).toByteArray()
    }

    fun nativeResolveExportTickRange(scoreHandle: Long, rangeBytes: ByteArray): LongArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeResolveExportTickRange(
            scoreHandle,
            SwiftData.fromByteArray(rangeBytes, arena),
        )
    }

    fun nativeBuildClickSoundFont(strongWav: ByteArray, weakWav: ByteArray): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeBuildClickSoundFont(
            SwiftData.fromByteArray(strongWav, arena),
            SwiftData.fromByteArray(weakWav, arena),
            arena,
        ).toByteArray()
    }
}
