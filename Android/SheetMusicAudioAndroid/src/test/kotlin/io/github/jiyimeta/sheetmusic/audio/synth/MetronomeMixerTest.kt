package io.github.jiyimeta.sheetmusic.audio.synth

import android.content.Context
import android.net.Uri
import io.github.jiyimeta.sheetmusic.audio.fakes.FakePlayerDriver
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-Kotlin unit tests for [MetronomeMixer].
 *
 * The clicks themselves live on the mixer's own [PlayerDriver] (a MIDI transport), so what there is to
 * assert here is that the transport is driven in lockstep with the score's — plus the count-in click,
 * which is the one thing still fired by hand because it happens before either transport starts.
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
        val allNotesOffChannels = mutableListOf<Int>()
        var closed = false

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
        override fun allNotesOff(channel: Int) { allNotesOffChannels += channel }
        override fun handleMidiEvent(rawEvent: Long) {}
        override fun writeFloat(frameCount: Int, left: FloatArray, right: FloatArray): Int = 0
        override fun close() { closed = true }
    }

    // -----------------------------------------------------------------------
    // Transport
    // -----------------------------------------------------------------------

    /**
     * A click transport with a sequence loaded, which is how the engine hands one to the mixer. A
     * [PlayerDriver] only acquires its native handle in `load`, and no-ops every call until it has one.
     */
    private fun mixerWithSequence(
        synth: SynthDriver = FakeMetronomeSynth(),
    ): Pair<MetronomeMixer, FakePlayerDriver.RecordingBindings> {
        val bindings = FakePlayerDriver.RecordingBindings()
        val mixer = MetronomeMixer(synth) { smf ->
            PlayerDriver(0L, bindings).takeIf { it.load(smf) == 0 }
        }
        mixer.loadSequence(byteArrayOf(1, 2, 3))
        return mixer to bindings
    }

    @Test fun start_seeksTheClickTransportToTheScoreTickBeforePlaying() {
        val (mixer, bindings) = mixerWithSequence()

        mixer.start(tick = 1920L)

        assertEquals("the click transport starts from the score's tick", listOf(1920L), bindings.seekTicks)
        assertEquals(1, bindings.playCalls.size)
    }

    @Test fun seekTick_movesTheClickTransportAndSilencesTheRingingClick() {
        val synth = FakeMetronomeSynth()
        val (mixer, bindings) = mixerWithSequence(synth)

        mixer.seekTick(960L)

        assertEquals(listOf(960L), bindings.seekTicks)
        assertEquals("channel 9 is the GM percussion channel", listOf(9), synth.allNotesOffChannels)
    }

    @Test fun setTempo_scalesTheClickTransport() {
        val (mixer, bindings) = mixerWithSequence()

        mixer.setTempo(1.5)

        // type 0 = FLUID_PLAYER_TEMPO_INTERNAL, the same scale the score player is given.
        assertEquals(listOf(0 to 1.5), bindings.setTempoCalls)
    }

    @Test fun loadSequence_reappliesTheRateToTheNewTransport() {
        val (mixer, bindings) = mixerWithSequence()
        mixer.setTempo(0.5)
        bindings.setTempoCalls.clear()

        // The count-in swaps in its own sequence mid-flight; a fresh transport starts at 1.0, so the
        // count would run at the notated tempo while the music it leads into runs at the set rate.
        mixer.loadSequence(byteArrayOf(4, 5, 6))

        assertEquals(listOf(0 to 0.5), bindings.setTempoCalls)
    }

    @Test fun resyncTo_putsAFrozenTransportBackOnTheBeat() {
        val (mixer, bindings) = mixerWithSequence()

        // While inaudible the metronome synth is not rendered, so its transport stopped advancing at
        // whatever tick it was switched off; becoming audible again has to re-place it.
        mixer.resyncTo(4800L)

        assertEquals(listOf(4800L), bindings.seekTicks)
    }

    @Test fun transportCallsNoOpWithoutASequence() {
        // An older native library returns no metronome SMF; the mixer then has no transport and the
        // metronome is simply silent rather than crashing on every transport call.
        val mixer = MetronomeMixer(FakeMetronomeSynth()) { null }
        mixer.loadSequence(byteArrayOf())

        mixer.start(0L)
        mixer.seekTick(480L)
        mixer.setTempo(2.0)
        mixer.resyncTo(960L)
        mixer.stop()
        assertEquals(0L, mixer.currentTick)
        mixer.close()
    }

    @Test fun close_releasesBothTheTransportAndTheSynth() {
        val synth = FakeMetronomeSynth()
        val (mixer, bindings) = mixerWithSequence(synth)

        mixer.close()

        assertTrue("the click transport must be released", bindings.closeCalled)
        assertTrue("the metronome synth must be released", synth.closed)
    }

    // -----------------------------------------------------------------------
    // Audibility
    // -----------------------------------------------------------------------

    @Test fun isAudible_isFalseOnlyWhenNeitherMetronomeNorCountInWantsSound() {
        val (mixer, _) = mixerWithSequence()

        assertFalse(mixer.isAudible)

        mixer.isEnabled = true
        assertTrue(mixer.isAudible)

        mixer.isEnabled = false
        mixer.isCountingIn = true
        assertTrue(mixer.isAudible)

        mixer.isCountingIn = false
        assertFalse(mixer.isAudible)
    }

    @Test fun volume_setter_callsSetGainOnSynth() {
        val synth = FakeMetronomeSynth()
        val (mixer, _) = mixerWithSequence(synth)

        mixer.volume = 0.5f

        assertTrue("setGain should be called with 0.5", synth.gainValues.contains(0.5f))
    }
}
