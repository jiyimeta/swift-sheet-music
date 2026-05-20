package io.github.jiyimeta.sheetmusic.audio.fakes

import android.content.Context
import android.net.Uri
import io.github.jiyimeta.sheetmusic.audio.synth.SynthDriver

/** Records all [SynthDriver] calls. No native code involved. */
internal class FakeSynthDriver(val id: Int = 0) : SynthDriver {
    val calls = mutableListOf<String>()
    var sfidToReturn: Int = 0

    /** Per-channel CC values. Tests can pre-seed these; cc() updates them. */
    private val ccValues = IntArray(16) { 100 }

    /** Per-channel type: false = melodic, true = drum. */
    val channelTypes = BooleanArray(16) { false }

    override val nativeHandle: Long = 0L

    override fun loadSoundFont(uri: Uri?, context: Context?): Int {
        calls += "loadSoundFont"
        return sfidToReturn
    }

    override fun programSelect(sfid: Int, channel: Int, bank: Int, program: Int) {
        calls += "programSelect($sfid,$channel,$bank,$program)"
    }

    override fun setGain(value: Float) { calls += "setGain($value)" }

    override fun cc(channel: Int, controller: Int, value: Int) {
        calls += "cc($channel,$controller,$value)"
        if (channel in 0 until 16) ccValues[channel] = value
    }

    override fun getCC(channel: Int, controller: Int): Int {
        calls += "getCC($channel,$controller)"
        return if (channel in 0 until 16) ccValues[channel] else -1
    }

    override fun setChannelType(channel: Int, isDrum: Boolean) {
        calls += "setChannelType($channel,${if (isDrum) "drum" else "melodic"})"
        if (channel in 0 until 16) channelTypes[channel] = isDrum
    }

    /** Seeds a CC value on a channel (used by tests to simulate prior SMF-emitted state). */
    fun seedCC(channel: Int, controller: Int, value: Int) {
        if (channel in 0 until 16) ccValues[channel] = value
    }

    override fun noteOn(channel: Int, pitch: Int, velocity: Int) {
        calls += "noteOn($channel,$pitch,$velocity)"
    }

    override fun noteOff(channel: Int, pitch: Int) {
        calls += "noteOff($channel,$pitch)"
    }

    override fun allNotesOff(channel: Int) { calls += "allNotesOff($channel)" }

    override fun handleMidiEvent(rawEvent: Long) { calls += "handleMidiEvent($rawEvent)" }

    /**
     * Render-loop test affordance. When a test wires this hook, [writeFloat]
     * invokes it after recording the call — typically to advance a linked
     * player's `tickToReturn` so the export render loop terminates on a
     * configurable schedule. Left `null` for tests that don't drive a loop.
     */
    var onWriteFloat: ((frameCount: Int) -> Unit)? = null

    /**
     * Convenience knob for render-loop tests. The hook installed by
     * [linkRenderLoopTo] reads this and advances the linked player by this
     * many ticks per [writeFloat] call. Treated as 0 (no advance) when no
     * hook is installed.
     */
    var tickAdvancePerWriteFloat: Int = 0

    override fun writeFloat(frameCount: Int, left: FloatArray, right: FloatArray): Int {
        calls += "writeFloat($frameCount)"
        onWriteFloat?.invoke(frameCount)
        return 0
    }

    override fun close() { calls += "close" }
}
