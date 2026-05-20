package io.github.kiichiio.sheetmusic.audio.jni

internal object SheetMusicAudioJNI {
    init {
        // libSheetMusicJNI.so is staged into jniLibs by the consumer app
        // (Scripts/android-build-libs.sh). This module does not vendor
        // the .so itself; the bindings just expect the JVM to find it
        // on the JNI library path.
        System.loadLibrary("SheetMusicJNI")
    }

    external fun nativeRenderMidi(scoreHandle: Long): ByteArray
    external fun nativeTimelineSummary(scoreHandle: Long): LongArray
    external fun nativeFrameAtTick(scoreHandle: Long, tick: Long): ByteArray
    external fun nativeFrameForCursor(scoreHandle: Long, cursorBytes: ByteArray): ByteArray
    external fun nativeMetronomeBeats(scoreHandle: Long): ByteArray
    external fun nativeStaffParams(scoreHandle: Long): ByteArray
    external fun nativePitchAndStaffOfNote(scoreHandle: Long, noteIdBytes: ByteArray): Long
    external fun nativeEarliestOf(scoreHandle: Long, idsBytes: ByteArray): ByteArray
    external fun nativeItemEndTick(scoreHandle: Long, idBytes: ByteArray): Long
}
