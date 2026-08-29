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

    /**
     * The UNROLLED transport tick a NOTATED score tick sits at — the write-side inverse of
     * [nativeFrameAtTick]'s read-side translation. Returns -1 for an unknown handle or a negative
     * input; the caller keeps its notated tick in that case.
     */
    fun nativeUnrolledTickForNotated(scoreHandle: Long, notatedTick: Long): Long =
        SwiftJavaJNI.nativeUnrolledTickForNotated(scoreHandle, notatedTick)

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

    fun nativeInstrumentParams(scoreHandle: Long): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeInstrumentParams(scoreHandle, arena).toByteArray()
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

    // ── Note auditions ───────────────────────────────────────────────
    //
    // The policy behind these lives in Swift and the Apple engine runs the same code. See
    // `NotePreviewBridge.swift`; this side only sends the MIDI its own synth wants.

    fun nativePreviewPolicyCreate(): Long = SwiftJavaJNI.nativePreviewPolicyCreate()

    fun nativePreviewPolicyRelease(policyHandle: Long) {
        SwiftJavaJNI.nativePreviewPolicyRelease(policyHandle)
    }

    fun nativePreviewPolicyBegin(
        policyHandle: Long,
        channel: Int,
        pitch: Int,
        velocity: Int,
        isDrum: Boolean,
        ringMilliseconds: Int,
    ): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativePreviewPolicyBegin(
            policyHandle,
            channel,
            pitch,
            velocity,
            isDrum,
            ringMilliseconds,
            arena,
        ).toByteArray()
    }

    fun nativePreviewPolicyEnd(policyHandle: Long, generation: Long): Long =
        SwiftJavaJNI.nativePreviewPolicyEnd(policyHandle, generation)

    fun nativePreviewPolicySilence(policyHandle: Long): Long =
        SwiftJavaJNI.nativePreviewPolicySilence(policyHandle)

    fun nativeMasterTuningControlChanges(cents: Double): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeMasterTuningControlChanges(cents, arena).toByteArray()
    }
}
