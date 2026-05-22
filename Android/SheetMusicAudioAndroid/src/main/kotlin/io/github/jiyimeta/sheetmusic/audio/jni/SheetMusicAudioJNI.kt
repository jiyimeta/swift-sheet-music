package io.github.jiyimeta.sheetmusic.audio.jni

import org.swift.swiftkit.core.SwiftMemoryManagement
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

    external fun nativeRenderMidi(scoreHandle: Long): ByteArray
    external fun nativeTimelineSummary(scoreHandle: Long): LongArray
    external fun nativeFrameAtTick(scoreHandle: Long, tick: Long): ByteArray
    external fun nativeFrameForCursor(scoreHandle: Long, cursorBytes: ByteArray): ByteArray
    external fun nativeMetronomeBeats(scoreHandle: Long): ByteArray
    external fun nativeStaffParams(scoreHandle: Long): ByteArray
    external fun nativeEarliestOf(scoreHandle: Long, idsBytes: ByteArray): ByteArray
    external fun nativeResolveExportTickRange(scoreHandle: Long, rangeBytes: ByteArray): LongArray

    // Migrated to swift-java — see Sources/SheetMusicAndroidJNI/AudioMidiBridge+Timeline.swift
    fun nativeGMInstrumentList(): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeGMInstrumentList(arena).toByteArray()
    }

    // Migrated to swift-java — see Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift
    fun nativePitchAndStaffOfNote(scoreHandle: Long, noteIdBytes: ByteArray): Long {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativePitchAndStaffOfNote(
            scoreHandle,
            io.github.jiyimeta.sheetmusic.swiftjava.Data.fromByteArray(noteIdBytes, arena),
        )
    }

    // Migrated to swift-java — see Sources/SheetMusicAndroidJNI/AudioMidiBridge+Timeline.swift
    fun nativeItemEndTick(scoreHandle: Long, idBytes: ByteArray): Long {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeItemEndTick(
            scoreHandle,
            io.github.jiyimeta.sheetmusic.swiftjava.Data.fromByteArray(idBytes, arena),
        )
    }
}
