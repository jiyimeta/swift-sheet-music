package io.github.kiichiio.sheetmusic.audio.fakes

import android.content.Context
import android.net.Uri
import io.github.kiichiio.sheetmusic.audio.synth.SynthDriver

/** Records all [SynthDriver] calls. No native code involved. */
internal class FakeSynthDriver(val id: Int = 0) : SynthDriver {
    val calls = mutableListOf<String>()
    var sfidToReturn: Int = 0

    override fun loadSoundFont(uri: Uri?, context: Context?): Int {
        calls += "loadSoundFont"
        return sfidToReturn
    }

    override fun programSelect(sfid: Int, channel: Int, bank: Int, program: Int) {
        calls += "programSelect($sfid,$channel,$bank,$program)"
    }

    override fun setGain(value: Float) { calls += "setGain($value)" }

    override fun noteOn(channel: Int, pitch: Int, velocity: Int) {
        calls += "noteOn($channel,$pitch,$velocity)"
    }

    override fun noteOff(channel: Int, pitch: Int) {
        calls += "noteOff($channel,$pitch)"
    }

    override fun allNotesOff(channel: Int) { calls += "allNotesOff($channel)" }

    override fun handleMidiEvent(rawEvent: Long) { calls += "handleMidiEvent($rawEvent)" }

    override fun writeFloat(frameCount: Int, left: FloatArray, right: FloatArray): Int {
        calls += "writeFloat($frameCount)"
        return 0
    }

    override fun close() { calls += "close" }
}
