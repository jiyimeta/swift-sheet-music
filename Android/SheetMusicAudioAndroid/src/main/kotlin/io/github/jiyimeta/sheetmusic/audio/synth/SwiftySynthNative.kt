package io.github.jiyimeta.sheetmusic.audio.synth

import org.swift.swiftkit.core.SwiftMemoryManagement
import io.github.jiyimeta.sheetmusic.swiftjava.Data as SwiftData
import io.github.jiyimeta.sheetmusic.swiftjava.SheetMusicAndroidJNI as SwiftJavaJNI

/**
 * The Swift side of playback: SwiftySynth synthesizers and the sequences playing on them, living in
 * `libSheetMusicAndroidJNI.so` (`Sources/SheetMusicAndroidJNI/Audio/SynthBridge.swift`).
 *
 * Handles are opaque `Long`s, `0L` meaning none. A handle stays valid until its `release` call and must not be used
 * after it — [SwiftySynthDriver] and [PlayerDriver] guard every call for exactly that reason.
 *
 * Everything but [nativeRender] goes through the swift-java bindings. [nativeRender] is a hand-written JNI function
 * that renders straight into the two arrays: one crossing per synth per output block, nothing allocated on either side.
 */
internal object SwiftySynthNative {
    init { System.loadLibrary("SheetMusicAndroidJNI") }

    /** Voicing argument of [synthCreate]: 256 voices with reverb and chorus. */
    const val VOICING_SCORE = 0

    /** Voicing argument of [synthCreate]: eight dry voices, for the click. */
    const val VOICING_METRONOME = 1

    /**
     * Renders [frames] stereo frames of the synth behind [handle] into the start of [left] / [right] and returns
     * [frames], or 0 — arrays untouched — for an unknown handle or arrays shorter than [frames].
     */
    external fun nativeRender(handle: Long, frames: Int, left: FloatArray, right: FloatArray): Int

    // ── Synth ────────────────────────────────────────────────────────

    fun synthCreate(sampleRate: Int, voicing: Int): Long = SwiftJavaJNI.nativeSynthCreate(sampleRate, voicing)
    fun synthRelease(handle: Long) = SwiftJavaJNI.nativeSynthRelease(handle)
    /** 0 on success, -1 when the file is missing or does not parse. */
    fun synthLoadSoundFont(handle: Long, path: String): Int = SwiftJavaJNI.nativeSynthLoadSoundFont(handle, path)
    fun synthProgramSelect(handle: Long, channel: Int, bank: Int, program: Int) =
        SwiftJavaJNI.nativeSynthProgramSelect(handle, channel, bank, program)
    fun synthControlChange(handle: Long, channel: Int, controller: Int, value: Int) =
        SwiftJavaJNI.nativeSynthControlChange(handle, channel, controller, value)
    fun synthControllerValue(handle: Long, channel: Int, controller: Int): Int =
        SwiftJavaJNI.nativeSynthControllerValue(handle, channel, controller)
    fun synthSetGain(handle: Long, gain: Float) = SwiftJavaJNI.nativeSynthSetGain(handle, gain.toDouble())
    fun synthNoteOn(handle: Long, channel: Int, key: Int, velocity: Int) =
        SwiftJavaJNI.nativeSynthNoteOn(handle, channel, key, velocity)
    fun synthNoteOff(handle: Long, channel: Int, key: Int) = SwiftJavaJNI.nativeSynthNoteOff(handle, channel, key)
    fun synthAllNotesOff(handle: Long, channel: Int) = SwiftJavaJNI.nativeSynthAllNotesOff(handle, channel)

    // ── Sequence ─────────────────────────────────────────────────────

    /** Attaches [smf] to the synth behind [synthHandle]; 0 when the bytes are not an SMF. */
    fun sequenceCreate(synthHandle: Long, smf: ByteArray): Long {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeSequenceCreate(synthHandle, SwiftData.fromByteArray(smf, arena))
    }
    fun sequenceRelease(handle: Long) = SwiftJavaJNI.nativeSequenceRelease(handle)
    fun sequencePlay(handle: Long) = SwiftJavaJNI.nativeSequencePlay(handle)
    fun sequenceStop(handle: Long) = SwiftJavaJNI.nativeSequenceStop(handle)
    fun sequenceSeek(handle: Long, tick: Long) = SwiftJavaJNI.nativeSequenceSeek(handle, tick)
    fun sequenceCurrentTick(handle: Long): Long = SwiftJavaJNI.nativeSequenceCurrentTick(handle)
    fun sequenceSetSpeed(handle: Long, speed: Double) = SwiftJavaJNI.nativeSequenceSetSpeed(handle, speed)
}
