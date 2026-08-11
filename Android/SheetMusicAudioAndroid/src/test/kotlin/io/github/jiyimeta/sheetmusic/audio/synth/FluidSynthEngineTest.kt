package io.github.jiyimeta.sheetmusic.audio.synth

import android.content.Context
import android.net.Uri
import io.github.jiyimeta.sheetmusic.audio.SoundfontResolver
import io.github.jiyimeta.sheetmusic.audio.model.StaffParams
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

    /** Per-channel CC values — tests can seed and read these back. */
    private val ccValues = IntArray(16) { 100 }

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
        if (channel in 0 until 16) ccValues[channel] = value
    }

    override fun getCC(channel: Int, controller: Int): Int {
        calls += "getCC($channel,$controller)"
        return if (channel in 0 until 16) ccValues[channel] else -1
    }

    override fun setChannelType(channel: Int, isDrum: Boolean) {
        calls += "setChannelType($channel,${if (isDrum) "drum" else "melodic"})"
    }

    /** Seeds a CC value on a channel (used by tests to simulate prior SMF-emitted state). */
    fun seedCC(channel: Int, value: Int) { if (channel in 0 until 16) ccValues[channel] = value }

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

private fun fakeStaffParams(index: Int, isDrums: Boolean = false) = StaffParams(
    staffIndex = index,
    bankLSB = 0,
    program = 0,
    isDrums = isDrums,
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

        assertEquals(3, engine.channelCount)
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

        assertEquals(0, engine.channelCount)
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
        assertEquals(2, engine.channelCount)
    }

    // ── Bug 1: drum channel routing ─────────────────────────────────────────

    @Test fun setupStaves_drumStaff_callsSetChannelTypeDrum() {
        val engine = FluidSynthEngine(synthFactory = { _ ->
            FakeSynth().also { capturedSynth = it }
        })
        engine.setupStaves(
            params = listOf(
                fakeStaffParams(0, isDrums = false),
                fakeStaffParams(1, isDrums = true),
            ),
            resolver = FakeResolver(),
            context = null,
        )
        val synth = capturedSynth!!
        assertTrue(
            "drum staff should call setChannelType drum on its channel",
            synth.calls.contains("setChannelType(1,drum)"),
        )
    }

    @Test fun setupStaves_opensBreathControllerOnMelodicChannels() {
        // MuseScore's "expressive" banks implement single-note dynamics with
        // SF2 modulators that put ~80 dB of initialAttenuation under CC2
        // (breath) control — verified by reading MuseScore_General's pmod
        // chunk for bank 17 program 21 ("Accordion Expr."):
        //     MOD src=CC2 -> initialAttenuation amount=800  (x2)
        //     MOD src=CC2 -> initialFilterFc    amount=-3600 / -2000
        // MuseScore streams CC2 while playing; this engine never sends it, so
        // such a preset sits at the attenuated end and the part is SILENT.
        // Open the controller at setup so the authored timbre is audible.
        // Bank-0 presets carry no CC2 modulators, so this is inert for them.
        val engine = buildEngine()

        setupStaves(engine, 2)

        val synth = capturedSynth!!
        assertTrue(
            "melodic channel 0 should have CC2 opened, got ${synth.calls}",
            synth.calls.contains("cc(0,2,127)"),
        )
        assertTrue(
            "melodic channel 1 should have CC2 opened, got ${synth.calls}",
            synth.calls.contains("cc(1,2,127)"),
        )
    }

    @Test fun setupStaves_doesNotOpenBreathControllerOnDrumChannels() {
        // A percussion preset has no single-note-dynamics gating to release,
        // and CC2 there would be an unrequested change to drum-kit behavior.
        val engine = FluidSynthEngine(synthFactory = { _ ->
            FakeSynth().also { capturedSynth = it }
        })
        engine.setupStaves(
            params = listOf(
                fakeStaffParams(0, isDrums = false),
                fakeStaffParams(1, isDrums = true),
            ),
            resolver = FakeResolver(),
            context = null,
        )
        val synth = capturedSynth!!
        assertTrue(
            "melodic channel keeps CC2, got ${synth.calls}",
            synth.calls.contains("cc(0,2,127)"),
        )
        assertTrue(
            "drum channel must not get CC2, got ${synth.calls}",
            synth.calls.none { it == "cc(1,2,127)" },
        )
    }

    @Test fun setupStaves_drumStaff_selectsBank128() {
        val engine = FluidSynthEngine(synthFactory = { _ ->
            FakeSynth().also { capturedSynth = it }
        })
        engine.setupStaves(
            params = listOf(
                fakeStaffParams(0, isDrums = false),
                fakeStaffParams(1, isDrums = true),
            ),
            resolver = FakeResolver(),
            context = null,
        )
        val synth = capturedSynth!!
        // The drum staff (channel 1) should programSelect with bank=128.
        assertTrue(
            "drum staff programSelect should use bank=128",
            synth.calls.any { it.startsWith("programSelect(") && it.contains(",1,128,") },
        )
    }

    @Test fun setupStaves_melodicStaff_doesNotCallSetChannelTypeDrum() {
        val engine = buildEngine()
        setupStaves(engine, 2) // all melodic (isDrums = false)
        val synth = capturedSynth!!
        assertTrue(
            "melodic staves should not call setChannelType drum",
            synth.calls.none { it.contains("setChannelType") && it.contains("drum") },
        )
    }

    // ── Bug 2: CC7 round-trip on mute/unmute ────────────────────────────────

    @Test fun muteUnmute_withoutSlider_restoresPreviousCC7() {
        val engine = buildEngine()
        setupStaves(engine, 2)
        val synth = capturedSynth!!
        // Simulate the channel having CC7 = 100 (SMF-emitted default, already set in FakeSynth).
        synth.seedCC(channel = 0, value = 100)
        synth.calls.clear()

        // Mute: captures CC7=100, writes CC7=0.
        engine.muteChannel(0)
        assertTrue("muteChannel should send CC7=0", synth.calls.contains("cc(0,7,0)"))

        synth.calls.clear()

        // Unmute: should restore CC7=100, NOT 127.
        engine.unmuteChannel(0)
        assertTrue(
            "unmuteChannel should restore CC7=100 (not 127)",
            synth.calls.contains("cc(0,7,100)"),
        )
        assertFalse(
            "unmuteChannel should NOT write CC7=127",
            synth.calls.contains("cc(0,7,127)"),
        )
    }

    @Test fun muteUnmute_afterSliderChange_restoresSliderValue() {
        val engine = buildEngine()
        setupStaves(engine, 2)
        val synth = capturedSynth!!
        synth.calls.clear()

        // User moves slider to 0.6 → CC7 = 76
        engine.setChannelVolume(0, 0.6f)
        assertTrue(synth.calls.contains("cc(0,7,76)"))
        synth.calls.clear()

        // Mute then unmute.
        engine.muteChannel(0)
        synth.calls.clear()
        engine.unmuteChannel(0)

        // Should restore the slider-set value (76), not the initial default (100).
        assertTrue(
            "unmuteChannel should restore user-set CC7=76",
            synth.calls.contains("cc(0,7,76)"),
        )
    }

    @Test fun setChannelVolume_whileMuted_doesNotWriteToSynth() {
        val engine = buildEngine()
        setupStaves(engine, 1)
        val synth = capturedSynth!!

        engine.muteChannel(0)
        synth.calls.clear()

        // Slider change while muted: should NOT write CC7 (channel is silent).
        engine.setChannelVolume(0, 0.8f)
        assertFalse(
            "setChannelVolume while muted should not write CC7 to the synth",
            synth.calls.any { it.startsWith("cc(0,7,") },
        )
    }

    @Test fun doubleMute_doesNotOverwriteRememberedCC7() {
        val engine = buildEngine()
        setupStaves(engine, 1)
        val synth = capturedSynth!!
        synth.seedCC(channel = 0, value = 90)
        synth.calls.clear()

        engine.muteChannel(0) // remembers 90
        // Seed a different value to simulate a SMF CC7 that arrived while muted.
        synth.seedCC(channel = 0, value = 50)
        engine.muteChannel(0) // already muted — must not overwrite remembered value
        synth.calls.clear()

        engine.unmuteChannel(0)
        assertTrue(
            "double-mute should restore first-captured CC7=90",
            synth.calls.contains("cc(0,7,90)"),
        )
    }

    // ── T4: setStaffProgram ─────────────────────────────────────────────────

    /**
     * Helper that sets up one melodic staff with bankLSB and program for T4 tests.
     * FakeSynth.loadSoundFont always returns sfid=0.
     */
    private fun setupStavesMelodic(engine: FluidSynthEngine, count: Int) {
        engine.setupStaves(
            params = (0 until count).map { fakeStaffParams(it, isDrums = false) },
            resolver = FakeResolver(),
            context = null,
        )
    }

    @Test fun setStaffProgram_callsProgramSelectOnExistingSfid() {
        val engine = buildEngine()
        setupStavesMelodic(engine, 1)
        val synth = capturedSynth!!
        // Clear setupStaves' initial programSelect calls so we only see setStaffProgram's call.
        synth.calls.clear()

        engine.setStaffProgram(0, 40)

        // sfid=0 (FakeSynth returns 0), channel=0, bank=0 (melodic, bankLSB=0), program=40
        assertTrue(
            "setStaffProgram should issue programSelect(sfid=0,channel=0,bank=0,program=40)",
            synth.calls.contains("programSelect(0,0,0,40)"),
        )
    }

    @Test fun setStaffProgram_onDrumStaff_usesBank128() {
        val engine = FluidSynthEngine(synthFactory = { _ ->
            FakeSynth().also { capturedSynth = it }
        })
        engine.setupStaves(
            params = listOf(fakeStaffParams(0, isDrums = true)),
            resolver = FakeResolver(),
            context = null,
        )
        val synth = capturedSynth!!
        synth.calls.clear()

        engine.setStaffProgram(0, 8)

        // Drum staff: bank=128, program=8
        assertTrue(
            "setStaffProgram on drum staff should issue programSelect with bank=128",
            synth.calls.contains("programSelect(0,0,128,8)"),
        )
    }

    @Test fun setStaffProgram_clampsProgram() {
        val engine = buildEngine()
        setupStavesMelodic(engine, 1)
        val synth = capturedSynth!!
        synth.calls.clear()

        engine.setStaffProgram(0, 999)

        // Program clamped to 127
        assertTrue(
            "setStaffProgram should clamp program to 127",
            synth.calls.contains("programSelect(0,0,0,127)"),
        )
    }

    @Test fun setStaffProgram_noOpsBeforeSetupStaves() {
        val engine = buildEngine()
        // No setupStaves — synth is null, loadedSfid=-1, staffLoadParams empty.

        engine.setStaffProgram(0, 40)

        // capturedSynth is null since factory was never called.
        assertTrue(
            "setStaffProgram before setupStaves should record no programSelect calls",
            capturedSynth == null || capturedSynth!!.calls.none { it.startsWith("programSelect") },
        )
    }

    @Test fun setStaffProgram_noOpsForOutOfRangeStaff() {
        val engine = buildEngine()
        setupStavesMelodic(engine, 1) // staffCount=1, valid index is 0 only
        val synth = capturedSynth!!
        synth.calls.clear()

        engine.setStaffProgram(99, 40)

        assertFalse(
            "setStaffProgram with out-of-range staffIndex should not call programSelect",
            synth.calls.any { it.startsWith("programSelect") },
        )
    }

    @Test fun setStaffProgram_clampsNegativeProgram() {
        val engine = buildEngine()
        setupStavesMelodic(engine, 1)
        val synth = capturedSynth!!
        synth.calls.clear()

        engine.setStaffProgram(0, -5)

        assertTrue(
            "setStaffProgram should clamp negative program to 0",
            synth.calls.contains("programSelect(0,0,0,0)"),
        )
    }
}
