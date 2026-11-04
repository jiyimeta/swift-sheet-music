package io.github.jiyimeta.sheetmusic.audio.synth

import android.content.Context
import android.net.Uri

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
}
