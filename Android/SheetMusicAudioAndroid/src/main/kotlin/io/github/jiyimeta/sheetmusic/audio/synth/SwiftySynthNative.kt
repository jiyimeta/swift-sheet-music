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
/** The native calls [SwiftySynthDriver] makes, so a test can stand in for the library. */
internal interface SynthNativeCalls {
    fun synthRelease(handle: Long)
    fun synthLoadSoundFont(handle: Long, path: String): Int
    fun synthProgramSelect(handle: Long, channel: Int, bank: Int, program: Int)
    fun synthControlChange(handle: Long, channel: Int, controller: Int, value: Int)
    fun synthControllerValue(handle: Long, channel: Int, controller: Int): Int
    fun synthSetGain(handle: Long, gain: Float)
    fun synthNoteOn(handle: Long, channel: Int, key: Int, velocity: Int)
    fun synthNoteOff(handle: Long, channel: Int, key: Int)
    fun synthPitchBend(handle: Long, channel: Int, value: Int)
    fun synthAllNotesOff(handle: Long, channel: Int)
    fun nativeRender(handle: Long, frames: Int, left: FloatArray, right: FloatArray): Int
    fun sequenceCreate(synthHandle: Long, smf: ByteArray): Long

    // ── Recordings (`RecordingBridge.swift`) ──
    //
    // Defaults answer as a library without recordings would, so a test's stand-in implements only what it checks.
    fun nativeRenderMix(
        scoreHandle: Long,
        metronomeHandle: Long,
        metronomeAudible: Boolean,
        frames: Int,
        left: FloatArray,
        right: FloatArray,
        metronomeLeft: FloatArray,
        metronomeRight: FloatArray,
    ): Int = 0
    fun recordingsClear(handle: Long) {}
    fun recordingsStage(
        handle: Long, id: String, pcmPath: String, offsetSeconds: Double, transposeSemitones: Int, volume: Double,
        muted: Boolean, soloed: Boolean,
    ) {}
    fun recordingsCommit(handle: Long, soloing: Boolean, readerTransposeSemitones: Int): Int = 0
    fun alignmentClear(handle: Long) {}
    fun alignmentAddSpan(handle: Long, start: Double, end: Double, duration: Double) {}
    fun alignmentAddSegment(
        handle: Long, trackId: String, sourceStart: Double, sourceEnd: Double, outputStart: Double,
    ) {}
    fun alignmentCommit(handle: Long): Int = 0
    fun countInDuration(handle: Long, seconds: Double): Double = seconds
    fun countInSpeed(handle: Long, seconds: Double): Double = 0.0
    fun currentOutputSeconds(handle: Long): Double = 0.0
    fun outputSecondsAtTick(handle: Long, tick: Long): Double = 0.0
    fun tickAtOutputSeconds(handle: Long, seconds: Double): Long = 0L
    fun recordingsPrefetch(handle: Long, loopStartTick: Long) {}
}

internal object SwiftySynthNative : SynthNativeCalls {
    init { System.loadLibrary("SheetMusicAndroidJNI") }

    /** Voicing argument of [synthCreate]: 256 voices with reverb and chorus. */
    const val VOICING_SCORE = 0

    /** Voicing argument of [synthCreate]: eight dry voices, for the click. */
    const val VOICING_METRONOME = 1

    /**
     * Renders [frames] stereo frames of the synth behind [handle] into the start of [left] / [right] and returns
     * [frames], or 0 — arrays untouched — for an unknown handle or arrays shorter than [frames].
     */
    external override fun nativeRender(handle: Long, frames: Int, left: FloatArray, right: FloatArray): Int

    /**
     * Renders [frames] frames of the score synth behind [scoreHandle], its recordings mixed in, into [left] / [right],
     * and of the metronome synth behind [metronomeHandle] (0 for none) into [metronomeLeft] / [metronomeRight] —
     * zeroed unless [metronomeAudible]. Returns [frames], or 0 — arrays untouched — for an unknown score handle or
     * arrays shorter than [frames]. Hand-written JNI, like [nativeRender]: one crossing per block, no allocation.
     */
    external override fun nativeRenderMix(
        scoreHandle: Long,
        metronomeHandle: Long,
        metronomeAudible: Boolean,
        frames: Int,
        left: FloatArray,
        right: FloatArray,
        metronomeLeft: FloatArray,
        metronomeRight: FloatArray,
    ): Int

    // ── Recordings ───────────────────────────────────────────────────

    override fun recordingsClear(handle: Long) = SwiftJavaJNI.nativeSynthRecordingsClear(handle)
    override fun recordingsStage(
        handle: Long, id: String, pcmPath: String, offsetSeconds: Double, transposeSemitones: Int, volume: Double,
        muted: Boolean, soloed: Boolean,
    ) = SwiftJavaJNI.nativeSynthRecordingsStage(
        handle, id, pcmPath, offsetSeconds, transposeSemitones, volume, muted, soloed,
    )
    override fun recordingsCommit(handle: Long, soloing: Boolean, readerTransposeSemitones: Int): Int =
        SwiftJavaJNI.nativeSynthRecordingsCommit(handle, soloing, readerTransposeSemitones)
    override fun alignmentClear(handle: Long) = SwiftJavaJNI.nativeSynthAlignmentClear(handle)
    override fun alignmentAddSpan(handle: Long, start: Double, end: Double, duration: Double) =
        SwiftJavaJNI.nativeSynthAlignmentAddSpan(handle, start, end, duration)
    override fun alignmentAddSegment(
        handle: Long, trackId: String, sourceStart: Double, sourceEnd: Double, outputStart: Double,
    ) = SwiftJavaJNI.nativeSynthAlignmentAddSegment(handle, trackId, sourceStart, sourceEnd, outputStart)
    override fun alignmentCommit(handle: Long): Int = SwiftJavaJNI.nativeSynthAlignmentCommit(handle)
    override fun countInDuration(handle: Long, seconds: Double): Double =
        SwiftJavaJNI.nativeSynthCountInDuration(handle, seconds)
    override fun countInSpeed(handle: Long, seconds: Double): Double =
        SwiftJavaJNI.nativeSynthCountInSpeed(handle, seconds)
    override fun currentOutputSeconds(handle: Long): Double = SwiftJavaJNI.nativeSynthCurrentOutputSeconds(handle)
    override fun outputSecondsAtTick(handle: Long, tick: Long): Double =
        SwiftJavaJNI.nativeSynthOutputSecondsAtTick(handle, tick)
    override fun tickAtOutputSeconds(handle: Long, seconds: Double): Long =
        SwiftJavaJNI.nativeSynthTickAtOutputSeconds(handle, seconds)
    override fun recordingsPrefetch(handle: Long, loopStartTick: Long) =
        SwiftJavaJNI.nativeSynthRecordingsPrefetch(handle, loopStartTick)

    /** Reads the score synth's recordings through Signalsmith Stretch, so they keep their pitch away from 100 %. */
    fun enableRecordingStretch(handle: Long) = SwiftJavaJNI.nativeSynthEnableRecordingStretch(handle)

    // ── Synth ────────────────────────────────────────────────────────

    fun synthCreate(sampleRate: Int, voicing: Int): Long = SwiftJavaJNI.nativeSynthCreate(sampleRate, voicing)
    override fun synthRelease(handle: Long) = SwiftJavaJNI.nativeSynthRelease(handle)
    /** 0 on success, -1 when the file is missing or does not parse. */
    override fun synthLoadSoundFont(handle: Long, path: String): Int = SwiftJavaJNI.nativeSynthLoadSoundFont(handle, path)
    override fun synthProgramSelect(handle: Long, channel: Int, bank: Int, program: Int) =
        SwiftJavaJNI.nativeSynthProgramSelect(handle, channel, bank, program)
    override fun synthControlChange(handle: Long, channel: Int, controller: Int, value: Int) =
        SwiftJavaJNI.nativeSynthControlChange(handle, channel, controller, value)
    override fun synthControllerValue(handle: Long, channel: Int, controller: Int): Int =
        SwiftJavaJNI.nativeSynthControllerValue(handle, channel, controller)
    override fun synthSetGain(handle: Long, gain: Float) = SwiftJavaJNI.nativeSynthSetGain(handle, gain.toDouble())
    override fun synthNoteOn(handle: Long, channel: Int, key: Int, velocity: Int) =
        SwiftJavaJNI.nativeSynthNoteOn(handle, channel, key, velocity)
    override fun synthNoteOff(handle: Long, channel: Int, key: Int) = SwiftJavaJNI.nativeSynthNoteOff(handle, channel, key)
    override fun synthPitchBend(handle: Long, channel: Int, value: Int) =
        SwiftJavaJNI.nativeSynthPitchBend(handle, channel, value)
    override fun synthAllNotesOff(handle: Long, channel: Int) = SwiftJavaJNI.nativeSynthAllNotesOff(handle, channel)

    // ── Sequence ─────────────────────────────────────────────────────

    /** Attaches [smf] to the synth behind [synthHandle]; 0 when the bytes are not an SMF. */
    override fun sequenceCreate(synthHandle: Long, smf: ByteArray): Long {
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
