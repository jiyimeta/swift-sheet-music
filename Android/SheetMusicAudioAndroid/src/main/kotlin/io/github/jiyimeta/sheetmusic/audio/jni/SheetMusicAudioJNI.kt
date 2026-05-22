package io.github.jiyimeta.sheetmusic.audio.jni

import org.swift.swiftkit.core.SwiftMemoryManagement
import io.github.jiyimeta.sheetmusic.swiftjava.Data as SwiftData
import io.github.jiyimeta.sheetmusic.swiftjava.SheetMusicAndroidJNI as SwiftJavaJNI

internal object SheetMusicAudioJNI {
    init {
        // Force-load io.github.jiyimeta.sheetmusic.SheetMusicJNI so its
        // static initialiser runs System.loadLibrary("SheetMusicJNI")
        // before any of our external fun calls bind. Direct reference
        // to a member (not just the class) guarantees class init.
        @Suppress("UNUSED_EXPRESSION")
        io.github.jiyimeta.sheetmusic.SheetMusicJNI.toString()
    }

    external fun nativeResolveExportTickRange(scoreHandle: Long, rangeBytes: ByteArray): LongArray

    // All other entry points have been migrated to swift-java. The Kotlin
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

    fun nativeMetronomeBeats(scoreHandle: Long): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeMetronomeBeats(scoreHandle, arena).toByteArray()
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
}
