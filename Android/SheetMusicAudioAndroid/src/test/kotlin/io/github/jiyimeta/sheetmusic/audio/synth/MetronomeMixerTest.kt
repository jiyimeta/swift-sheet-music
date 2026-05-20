package io.github.jiyimeta.sheetmusic.audio.synth

import android.content.Context
import android.net.Uri
import io.github.jiyimeta.sheetmusic.audio.model.MetronomeBeat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-Kotlin unit tests for [MetronomeMixer].
 *
 * All tests use [FakeMetronomeSynth], which records noteOn/noteOff/setGain
 * calls without touching any Android runtime APIs.
 */
class MetronomeMixerTest {

    // -----------------------------------------------------------------------
    // Fake SynthDriver
    // -----------------------------------------------------------------------

    private class FakeMetronomeSynth : SynthDriver {
        data class NoteOnCall(val channel: Int, val pitch: Int, val velocity: Int)
        data class NoteOffCall(val channel: Int, val pitch: Int)

        val noteOns = mutableListOf<NoteOnCall>()
        val noteOffs = mutableListOf<NoteOffCall>()
        val gainValues = mutableListOf<Float>()

        override val nativeHandle: Long = 0L

        override fun loadSoundFont(uri: Uri?, context: Context?): Int = 0
        override fun programSelect(sfid: Int, channel: Int, bank: Int, program: Int) {}
        override fun setGain(value: Float) { gainValues += value }
        override fun cc(channel: Int, controller: Int, value: Int) {}
        override fun getCC(channel: Int, controller: Int): Int = 100
        override fun setChannelType(channel: Int, isDrum: Boolean) {}
        override fun noteOn(channel: Int, pitch: Int, velocity: Int) {
            noteOns += NoteOnCall(channel, pitch, velocity)
        }
        override fun noteOff(channel: Int, pitch: Int) {
            noteOffs += NoteOffCall(channel, pitch)
        }
        override fun allNotesOff(channel: Int) {}
        override fun handleMidiEvent(rawEvent: Long) {}
        override fun writeFloat(frameCount: Int, left: FloatArray, right: FloatArray): Int = 0
        override fun close() {}
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    private fun downbeat(tick: Long) = MetronomeBeat(tick = tick, isDownbeat = true)
    private fun upbeat(tick: Long) = MetronomeBeat(tick = tick, isDownbeat = false)

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    @Test fun updateCurrentTick_firesBeatsInRange() {
        val fake = FakeMetronomeSynth()
        val mixer = MetronomeMixer(
            synth = fake,
            beats = listOf(downbeat(0), upbeat(480)),
        )
        mixer.isEnabled = true

        // First update: tick advances from -1 to 480 — should fire both beats.
        mixer.updateCurrentTick(480)

        assertEquals("two noteOn calls expected", 2, fake.noteOns.size)
        assertEquals("two noteOff calls expected", 2, fake.noteOffs.size)
    }

    @Test fun updateCurrentTick_firesEachBeatOnce() {
        val fake = FakeMetronomeSynth()
        val mixer = MetronomeMixer(
            synth = fake,
            beats = listOf(downbeat(0), upbeat(480)),
        )
        mixer.isEnabled = true

        mixer.updateCurrentTick(0)   // fires beat at tick 0
        mixer.updateCurrentTick(480) // fires beat at tick 480

        assertEquals("each beat fires exactly once", 2, fake.noteOns.size)
    }

    @Test fun updateCurrentTick_doesNotFireWhenDisabled() {
        val fake = FakeMetronomeSynth()
        val mixer = MetronomeMixer(
            synth = fake,
            beats = listOf(downbeat(0), upbeat(480)),
        )
        mixer.isEnabled = false

        mixer.updateCurrentTick(480)

        assertEquals("no noteOn when disabled", 0, fake.noteOns.size)
        assertEquals("no noteOff when disabled", 0, fake.noteOffs.size)
    }

    @Test fun downbeat_usesHigherPitchAndHigherVelocity() {
        val fake = FakeMetronomeSynth()
        val mixer = MetronomeMixer(
            synth = fake,
            beats = listOf(downbeat(0)),
        )
        mixer.isEnabled = true

        mixer.updateCurrentTick(0)

        val noteOn = fake.noteOns.first()
        assertEquals("downbeat pitch should be 76", 76, noteOn.pitch)
        assertEquals("downbeat velocity should be 96", 96, noteOn.velocity)
        assertEquals("percussion channel should be 9", 9, noteOn.channel)
    }

    @Test fun upbeat_usesLowerPitchAndLowerVelocity() {
        val fake = FakeMetronomeSynth()
        val mixer = MetronomeMixer(
            synth = fake,
            beats = listOf(upbeat(0)),
        )
        mixer.isEnabled = true

        mixer.updateCurrentTick(0)

        val noteOn = fake.noteOns.first()
        assertEquals("upbeat pitch should be 77", 77, noteOn.pitch)
        assertEquals("upbeat velocity should be 72", 72, noteOn.velocity)
        assertEquals("percussion channel should be 9", 9, noteOn.channel)
    }

    @Test fun noteOff_isAlwaysPairedWithNoteOn() {
        val fake = FakeMetronomeSynth()
        val mixer = MetronomeMixer(
            synth = fake,
            beats = listOf(downbeat(0), upbeat(240), downbeat(480)),
        )
        mixer.isEnabled = true

        mixer.updateCurrentTick(480)

        assertEquals(fake.noteOns.size, fake.noteOffs.size)
        // Each noteOff pitch matches its noteOn pitch.
        for (i in fake.noteOns.indices) {
            assertEquals(fake.noteOns[i].pitch, fake.noteOffs[i].pitch)
        }
    }

    @Test fun volume_setter_callsSetGainOnSynth() {
        val fake = FakeMetronomeSynth()
        val mixer = MetronomeMixer(synth = fake, beats = emptyList())

        mixer.volume = 0.5f

        assertTrue("setGain should be called with 0.5", fake.gainValues.contains(0.5f))
    }

    @Test fun updateCurrentTick_doesNotFireFutureBeats() {
        val fake = FakeMetronomeSynth()
        val mixer = MetronomeMixer(
            synth = fake,
            beats = listOf(downbeat(480), upbeat(960)),
        )
        mixer.isEnabled = true

        // Advance only to 240 — neither beat should fire.
        mixer.updateCurrentTick(240)

        assertEquals("no beats should fire before their tick", 0, fake.noteOns.size)
    }

    @Test fun updateCurrentTick_doesNotRepeatPastBeats() {
        val fake = FakeMetronomeSynth()
        val mixer = MetronomeMixer(
            synth = fake,
            beats = listOf(downbeat(0)),
        )
        mixer.isEnabled = true

        mixer.updateCurrentTick(0)   // fires tick 0 beat
        mixer.updateCurrentTick(10)  // tick 0 already passed — should NOT re-fire

        assertEquals("beat should fire exactly once", 1, fake.noteOns.size)
    }
}
