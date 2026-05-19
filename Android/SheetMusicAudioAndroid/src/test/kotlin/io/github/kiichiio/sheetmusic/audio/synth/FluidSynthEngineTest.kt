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

    // Backing buffers filled with a fixed value so tests can verify mixing.
    var fillValue: Float = 0f

    override fun loadSoundFont(uri: Uri?, context: Context?): Int {
        calls += "loadSoundFont"
        return 0 // sfid = 0
    }

    override fun programSelect(sfid: Int, channel: Int, bank: Int, program: Int) {
        calls += "programSelect($sfid,$channel,$bank,$program)"
    }

    override fun setGain(value: Float) { calls += "setGain($value)" }

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
 *
 * [android.net.Uri] is an Android SDK class whose constructors and factory
 * methods are unavailable in the JVM unit-test stub environment, so we
 * cannot construct a real Uri here.
 */
private class FakeResolver : SoundfontResolver {
    override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean): Uri? = null
    override val defaultGmSoundfontUri: Uri? = null
}

/** Stub [Context] accepted by [FakeSynth.loadSoundFont] but never dereferenced. */
private fun fakeContext(): Context = TODO("unreachable — FakeSynth.loadSoundFont ignores context")

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

class FluidSynthEngineTest {

    private fun buildEngine(fakes: MutableList<FakeSynth>): FluidSynthEngine {
        return FluidSynthEngine(
            synthFactory = { _ ->
                FakeSynth().also { fakes += it }
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

    @Test fun setupStaves_createsOneDriverPerStaff() {
        val fakes = mutableListOf<FakeSynth>()
        val engine = buildEngine(fakes)

        setupStaves(engine, 3)

        assertEquals(3, engine.staffCount)
        assertEquals(3, fakes.size)
    }

    @Test fun setupStaves_loadsSoundFontOnEachDriver() {
        val fakes = mutableListOf<FakeSynth>()
        val engine = buildEngine(fakes)

        setupStaves(engine, 3)

        fakes.forEach { fake ->
            assertTrue("loadSoundFont should be called", fake.calls.contains("loadSoundFont"))
        }
    }

    @Test fun setStaffGain_callsSetGainOnCorrectDriver() {
        val fakes = mutableListOf<FakeSynth>()
        val engine = buildEngine(fakes)

        setupStaves(engine, 3)
        // Reset call lists so prior setup calls don't interfere.
        fakes.forEach { it.calls.clear() }

        engine.setStaffGain(0, 0.5f)

        assertTrue("staff 0 should receive setGain(0.5)", fakes[0].calls.contains("setGain(0.5)"))
        assertTrue("staff 1 should not receive setGain", fakes[1].calls.none { it.startsWith("setGain") })
        assertTrue("staff 2 should not receive setGain", fakes[2].calls.none { it.startsWith("setGain") })
    }

    @Test fun allNotesOff_callsAllNotesOffOnEveryStaff() {
        val fakes = mutableListOf<FakeSynth>()
        val engine = buildEngine(fakes)

        setupStaves(engine, 2)
        fakes.forEach { it.calls.clear() }

        engine.allNotesOff()

        fakes.forEach { fake ->
            assertTrue(
                "every staff should receive allNotesOff(-1)",
                fake.calls.contains("allNotesOff(-1)"),
            )
        }
    }

    @Test fun writeMixedFloat_skipsMutedStaff_andSumsAudibleStaves() {
        val fakes = mutableListOf<FakeSynth>()
        val engine = buildEngine(fakes)

        setupStaves(engine, 3)

        // Staff 0 contributes 0.4, staff 1 is muted, staff 2 contributes 0.6.
        fakes[0].fillValue = 0.4f
        fakes[1].fillValue = 99f  // Should never be added.
        fakes[2].fillValue = 0.6f
        fakes.forEach { it.calls.clear() }

        val frameCount = 4
        val left = FloatArray(frameCount)
        val right = FloatArray(frameCount)
        engine.writeMixedFloat(
            frameCount, left, right,
            effectiveMutes = booleanArrayOf(false, true, false),
        )

        // Staff 1 must NOT have been asked to write.
        assertFalse(
            "muted staff should not call writeFloat",
            fakes[1].calls.any { it.startsWith("writeFloat") },
        )

        // Staves 0 and 2 must have been asked to write.
        assertTrue(fakes[0].calls.any { it.startsWith("writeFloat") })
        assertTrue(fakes[2].calls.any { it.startsWith("writeFloat") })

        // Mixed output = 0.4 + 0.6 = 1.0 for every frame.
        for (i in 0 until frameCount) {
            assertEquals("left[$i] should be 1.0", 1.0f, left[i], 0.001f)
            assertEquals("right[$i] should be 1.0", 1.0f, right[i], 0.001f)
        }
    }

    @Test fun teardown_closesAllDrivers() {
        val fakes = mutableListOf<FakeSynth>()
        val engine = buildEngine(fakes)

        setupStaves(engine, 2)
        fakes.forEach { it.calls.clear() }

        engine.teardown()

        assertEquals(0, engine.staffCount)
        fakes.forEach { fake ->
            assertTrue("each driver should be closed", fake.calls.contains("close"))
        }
    }
}
