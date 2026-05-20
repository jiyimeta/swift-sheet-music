package io.github.jiyimeta.sheetmusic.audio.synth

import android.content.Context
import android.net.Uri

/**
 * Lowest-level audio engine seam. Production: backed by FluidSynthNative.
 * Tests: backed by a fake recorder.
 *
 * Context and Uri parameters are nullable to allow JVM unit tests to pass
 * null without triggering Kotlin null-check intrinsics. Production code
 * always provides non-null values; fakes never dereference these params.
 */
internal interface SynthDriver {
    /** Native fluid_synth_t pointer. 0L for fakes. */
    val nativeHandle: Long

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
     * Sets the channel type: [isDrum]=true locks the channel into drum-channel
     * semantics (CHANNEL_TYPE_DRUM), allowing any channel number to act as
     * channel 9 for GM percussion.
     */
    fun setChannelType(channel: Int, isDrum: Boolean)
    fun noteOn(channel: Int, pitch: Int, velocity: Int)
    fun noteOff(channel: Int, pitch: Int)
    fun allNotesOff(channel: Int)
    fun handleMidiEvent(rawEvent: Long)
    fun writeFloat(frameCount: Int, left: FloatArray, right: FloatArray): Int
    fun close()
}
