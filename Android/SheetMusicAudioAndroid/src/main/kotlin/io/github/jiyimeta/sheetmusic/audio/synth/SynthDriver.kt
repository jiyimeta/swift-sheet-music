package io.github.jiyimeta.sheetmusic.audio.synth

import android.content.Context
import android.net.Uri
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackAlignment
import io.github.jiyimeta.sheetmusic.audio.model.RecordingTrack

/**
 * Lowest-level audio engine seam. Production: [SwiftySynthDriver], a SwiftySynth synthesizer in Swift.
 * Tests: backed by a fake recorder.
 *
 * Context and Uri parameters are nullable to allow JVM unit tests to pass
 * null without triggering Kotlin null-check intrinsics. Production code
 * always provides non-null values; fakes never dereference these params.
 */
internal interface SynthDriver {
    /**
     * A native sequence over [smf] attached to this synth, made under the driver's own lock; 0 once the driver is
     * closed or when the bytes are not an SMF. The synth's handle itself is never handed out — see
     * [SwiftySynthDriver.attachSequence].
     */
    fun attachSequence(smf: ByteArray): Long

    /**
     * Loads SF2 at [uri], copying to cache if needed. Returns sfid or -1 on failure.
     * [context] is nullable to facilitate JVM unit testing without an Android runtime.
     */
    fun loadSoundFont(uri: Uri?, context: Context?): Int
    fun programSelect(sfid: Int, channel: Int, bank: Int, program: Int)
    fun setGain(value: Float)
    fun cc(channel: Int, controller: Int, value: Int)
    /**
     * Reads MIDI CC [controller] value from [channel].
     * Returns the CC value (0–127), or -1 on failure / unsupported.
     */
    fun getCC(channel: Int, controller: Int): Int
    /**
     * Marks [channel] as a drum channel ([isDrum]=true) or a melodic one. A synth whose percussion channel is fixed
     * (SwiftySynth's is channel 9, where every drum part is rendered) treats this as a no-op.
     */
    fun setChannelType(channel: Int, isDrum: Boolean)
    fun noteOn(channel: Int, pitch: Int, velocity: Int)
    fun noteOff(channel: Int, pitch: Int)

    /**
     * Puts [channel]'s pitch wheel at [value] (14-bit, 8192 the center) for an audition, with the bend sensitivity the
     * playback renderer uses set first — so an audition's microtonal offset bends by what the same note bends in
     * playback. Not kept across the sequencer's resets, unlike a [cc].
     */
    fun pitchBend(channel: Int, value: Int)
    fun allNotesOff(channel: Int)
    fun writeFloat(frameCount: Int, left: FloatArray, right: FloatArray): Int
    fun close()

    // ── Recordings (a score synth's; see `HostedSynth+Recordings.swift`) ──
    //
    // Every default is a synth that plays no recordings: the engine then mixes as it always did, through [writeFloat].

    /**
     * Replaces the recordings mixed onto this synth's sequence. [soloing] is whether the solo bus is engaged (an
     * instrument strip or a recording soloed); [readerTransposeSemitones] is added to each track's own. False, the
     * playing tracks left as they were, when a file cannot be mapped.
     */
    fun setRecordingTracks(tracks: List<RecordingTrack>, soloing: Boolean, readerTransposeSemitones: Int): Boolean = true

    /** The alignment the transport and the recordings follow; false, nothing changed, for an invalid warp. */
    fun setAlignment(alignment: PlaybackAlignment): Boolean = true

    /**
     * Renders this synth with its recordings into [left] / [right] and [metronome] into [metronomeLeft] /
     * [metronomeRight] (zeroed unless [metronomeAudible]) in one call, the metronome's speed following this synth's
     * at every block start. False when this driver cannot — the caller then renders through [writeFloat].
     */
    fun renderMix(
        metronome: SynthDriver?,
        metronomeAudible: Boolean,
        frameCount: Int,
        left: FloatArray,
        right: FloatArray,
        metronomeLeft: FloatArray,
        metronomeRight: FloatArray,
    ): Boolean = false

    /** Where the attached sequence stands on the warped clock; NaN when this driver has no such clock. */
    fun currentOutputSeconds(): Double = Double.NaN

    /** The warped second of the attached sequence's [tick]; NaN when this driver has no such clock. */
    fun outputSecondsAtTick(tick: Long): Double = Double.NaN

    /** The attached sequence's tick at warped second [seconds]; -1 when this driver has no such clock. */
    fun tickAtOutputSeconds(seconds: Double): Long = -1L

    /**
     * Lays the attached sequence over the notated timeline of the score behind [scoreHandle] — the score it was
     * rendered from — for [notatedSecondsAtOutput] and [outputSecondsAtNotated]. Walks the whole score: call it when
     * that score changes, while nothing renders.
     */
    fun setTransportScore(scoreHandle: Long) {}

    /**
     * The notated second (the score's own timeline, repeats folded) warped second [seconds] stands for; NaN when this
     * driver has no such clock.
     */
    fun notatedSecondsAtOutput(seconds: Double): Double = Double.NaN

    /** The warped second notated second [seconds] first plays at; NaN when this driver has no such clock. */
    fun outputSecondsAtNotated(seconds: Double): Double = Double.NaN

    /**
     * How a count-in of [seconds] (its click sequence's own length) plays into where the sequence is parked: how long
     * the score waits, and the speed the click counts at under a warp (null without one: the user's rate). Null when
     * this driver cannot tell, and the caller divides by the rate as it always did.
     */
    fun countIn(seconds: Double): CountInTiming? = null

    /** Reads the recordings' next pages in from where the transport is, and from [loopStartTick] when it is ≥ 0. */
    fun prefetchRecordings(loopStartTick: Long) {}
}

/** [SynthDriver.countIn]'s answer. */
internal data class CountInTiming(val durationSeconds: Double, val speed: Double?)
