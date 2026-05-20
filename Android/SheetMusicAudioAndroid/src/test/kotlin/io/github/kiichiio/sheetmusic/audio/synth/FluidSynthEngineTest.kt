package io.github.kiichiio.sheetmusic.audio.synth

import android.content.Context
import android.net.Uri
import io.github.kiichiio.sheetmusic.audio.SoundfontResolver
import io.github.kiichiio.sheetmusic.audio.model.StaffParams
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// ---------------------------------------------------------------------------
// Fake helpers
// ---------------------------------------------------------------------------

/** Records all SynthDriver calls for assertion in tests. */
private class FakeSynth : SynthDriver {
    val calls = mutableListOf<String>()

    // Backing buffers filled with a fixed value so tests can verify rendering.
    var fillValue: Float = 0f

    override val nativeHandle: Long = 42L

    override fun loadSoundFont(uri: Uri?, context: Context?): Int {
        calls += "loadSoundFont"
        return 0 // sfid = 0
    }

    override fun programSelect(sfid: Int, channel: Int, bank: Int, program: Int) {
        calls += "programSelect($sfid,$channel,$bank,$program)"
    }

    override fun setGain(value: Float) { calls += "setGain($value)" }

    override fun cc(channel: Int, controller: Int, value: Int) {
        calls += "cc($channel,$controller,$value)"
    }

    override fun noteOn(channel: Int, pitch: Int, velocity: Int) {
        calls += "noteOn($channel,$pitch,$velocity)"
    }

    override fun noteOff(channel: Int, pitch: Int) { calls += "noteOff($channel,$pitch)" }

    override fun allNotesOff(channel: Int) { calls += "allNotesOff($channel)" }

    override fun handleMidiEvent(rawEvent: Long) { calls += "handleMidiEvent($rawEvent)" }

    override fun writeFloat(frameCount: Int, left: FloatArray, right: FloatArray): Int {
        calls += "writeFloat($frameCount)"
        for (i in 0 until frameCount) { left[i] = fillValue; right[i] = fillValue }
        return 0
    }

    override fun close() { calls += "close" }
}

private fun fakeStaffParams(index: Int) = StaffParams(
    staffIndex = index,
    bankLSB = 0,
    program = 0,
    isDrums = false,
    partAddressHash = index.toLong(),
)

/**
 * Resolver used in JVM unit tests. Returns null for both URI methods so
 * [FakeSynth.loadSoundFont] is called with a null uri. The engine treats
 * a null uri as "no SoundFont loaded, staff is silent" — staff still
 * appears in the routing graph (staffCount is correct), just mute.
 */
private class FakeResolver : SoundfontResolver {
    override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean): Uri? = null
    override val defaultGmSoundfontUri: Uri? = null
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

class FluidSynthEngineTest {

    private var capturedSynth: FakeSynth? = null

    private fun buildEngine(): FluidSynthEngine {
        return FluidSynthEngine(
            synthFactory = { _ ->
                FakeSynth().also { capturedSynth = it }
            },
        )
    }

    /**
     * Helper that calls [FluidSynthEngine.setupStaves] with a null context.
     * [FluidSynthEngine.setupStaves] accepts [Context?], and [FakeSynth]
     * never dereferences the context, so null is safe here.
     */
    private fun setupStaves(engine: FluidSynthEngine, count: Int) {
        engine.setupStaves(
            params = (0 until count).map { fakeStaffParams(it) },
            resolver = FakeResolver(),
            context = null,
        )
    }

    @Test fun setupStaves_createsOneDriverForAllStaves() {
        var createCount = 0
        val engine = FluidSynthEngine(synthFactory = { _ ->
            createCount++
            FakeSynth().also { capturedSynth = it }
        })

        setupStaves(engine, 3)

        assertEquals(3, engine.staffCount)
        // Single synth — factory called exactly once.
        assertEquals(1, createCount)
    }

    @Test fun setupStaves_loadsSoundFontOnDriver() {
        val engine = buildEngine()

        setupStaves(engine, 3)

        val synth = capturedSynth!!
        assertTrue("loadSoundFont should be called once", synth.calls.contains("loadSoundFont"))
    }

    @Test fun setupStaves_programSelectCalledPerStaff() {
        val engine = buildEngine()

        setupStaves(engine, 3)

        val synth = capturedSynth!!
        // programSelect(sfid=0, channel=0, bank=0, program=0) through (channel=2)
        assertTrue(synth.calls.contains("programSelect(0,0,0,0)"))
        assertTrue(synth.calls.contains("programSelect(0,1,0,0)"))
        assertTrue(synth.calls.contains("programSelect(0,2,0,0)"))
    }

    @Test fun synthHandle_exposesNativeHandle() {
        val engine = buildEngine()
        // Before setup: 0L
        assertEquals(0L, engine.synthHandle)

        setupStaves(engine, 1)

        // After setup: matches FakeSynth.nativeHandle = 42L
        assertEquals(42L, engine.synthHandle)
    }

    @Test fun setChannelVolume_sendsCC7() {
        val engine = buildEngine()
        setupStaves(engine, 2)
        val synth = capturedSynth!!
        synth.calls.clear()

        engine.setChannelVolume(1, 0.5f)

        // CC7 = channel volume; 0.5 * 127 = 63 (int)
        assertTrue(
            "setChannelVolume should send CC7 on the staff's channel",
            synth.calls.contains("cc(1,7,63)"),
        )
    }

    @Test fun muteChannel_sendsCC7ZeroAndAllNotesOff() {
        val engine = buildEngine()
        setupStaves(engine, 2)
        val synth = capturedSynth!!
        synth.calls.clear()

        engine.muteChannel(0)

        assertTrue("muteChannel should send CC7=0", synth.calls.contains("cc(0,7,0)"))
        assertTrue("muteChannel should send allNotesOff", synth.calls.contains("allNotesOff(0)"))
    }

    @Test fun allNotesOff_callsAllNotesOffForEveryChannel() {
        val engine = buildEngine()
        setupStaves(engine, 3)
        val synth = capturedSynth!!
        synth.calls.clear()

        engine.allNotesOff()

        assertTrue(synth.calls.contains("allNotesOff(0)"))
        assertTrue(synth.calls.contains("allNotesOff(1)"))
        assertTrue(synth.calls.contains("allNotesOff(2)"))
    }

    @Test fun previewNoteOn_firesNoteOnWithCorrectChannel() {
        val engine = buildEngine()
        setupStaves(engine, 2)
        val synth = capturedSynth!!
        synth.calls.clear()

        engine.previewNoteOn(staffIndex = 1, pitch = 60, velocity = 96)

        assertTrue(synth.calls.contains("noteOn(1,60,96)"))
    }

    @Test fun previewNoteOff_firesNoteOff() {
        val engine = buildEngine()
        setupStaves(engine, 2)
        val synth = capturedSynth!!
        synth.calls.clear()

        engine.previewNoteOff(staffIndex = 0, pitch = 60)

        assertTrue(synth.calls.contains("noteOff(0,60)"))
    }

    @Test fun writeFloat_delegatesToSynth() {
        val engine = buildEngine()
        setupStaves(engine, 2)
        val synth = capturedSynth!!
        synth.fillValue = 0.5f
        synth.calls.clear()

        val left = FloatArray(4)
        val right = FloatArray(4)
        engine.writeFloat(4, left, right)

        assertTrue(synth.calls.any { it.startsWith("writeFloat") })
        // Output should contain the synth's fill value
        for (i in 0 until 4) {
            assertEquals(0.5f, left[i], 0.001f)
            assertEquals(0.5f, right[i], 0.001f)
        }
    }

    @Test fun writeFloat_zerosBuffersWhenNoSynth() {
        val engine = buildEngine()
        // No setupStaves called — synth is null.

        val left = FloatArray(4) { 99f }
        val right = FloatArray(4) { 99f }
        engine.writeFloat(4, left, right)

        for (i in 0 until 4) {
            assertEquals(0f, left[i], 0.001f)
            assertEquals(0f, right[i], 0.001f)
        }
    }

    @Test fun teardown_closesDriver_andResetsState() {
        val engine = buildEngine()
        setupStaves(engine, 2)
        val synth = capturedSynth!!
        synth.calls.clear()

        engine.teardown()

        assertEquals(0, engine.staffCount)
        assertEquals(0L, engine.synthHandle)
        assertTrue("driver should be closed", synth.calls.contains("close"))
    }

    @Test fun setupStaves_teardownOldSynthFirst() {
        var createCount = 0
        val synths = mutableListOf<FakeSynth>()
        val engine = FluidSynthEngine(synthFactory = { _ ->
            createCount++
            FakeSynth().also { synths += it }
        })

        setupStaves(engine, 1)
        val firstSynth = synths[0]
        assertFalse("first synth not yet closed", firstSynth.calls.contains("close"))

        // Second setup should close the first synth.
        setupStaves(engine, 2)
        assertTrue("first synth should be closed on re-setup", firstSynth.calls.contains("close"))
        assertEquals(2, engine.staffCount)
    }
}
