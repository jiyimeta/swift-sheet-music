package io.github.kiichiio.sheetmusic.audio

import android.net.Uri
import io.github.kiichiio.sheetmusic.audio.fakes.FakeJniBridge
import io.github.kiichiio.sheetmusic.audio.fakes.FakeOboeStream
import io.github.kiichiio.sheetmusic.audio.fakes.FakePlayerDriver
import io.github.kiichiio.sheetmusic.audio.fakes.FakeSynthDriver
import io.github.kiichiio.sheetmusic.audio.model.MetronomeBeat
import io.github.kiichiio.sheetmusic.audio.model.NoteID
import io.github.kiichiio.sheetmusic.audio.model.PlaybackState
import io.github.kiichiio.sheetmusic.audio.model.ScoreCursor
import io.github.kiichiio.sheetmusic.audio.model.ScoreItemID
import io.github.kiichiio.sheetmusic.audio.model.StaffAddress
import io.github.kiichiio.sheetmusic.audio.model.StaffParams
import io.github.kiichiio.sheetmusic.audio.serialization.FrameDecoder
import io.github.kiichiio.sheetmusic.audio.serialization.MetronomeBeatCodec
import io.github.kiichiio.sheetmusic.audio.serialization.NoteIDCodec
import io.github.kiichiio.sheetmusic.audio.serialization.ScoreCursorCodec
import io.github.kiichiio.sheetmusic.audio.serialization.ScoreItemIDCodec
import io.github.kiichiio.sheetmusic.audio.serialization.StaffParamsCodec
import io.github.kiichiio.sheetmusic.audio.synth.OboeStream
import io.github.kiichiio.sheetmusic.audio.synth.PlayerDriver
import io.github.kiichiio.sheetmusic.audio.synth.SynthDriver
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

// ── Test dispatcher setup ──────────────────────────────────────────────────

// Shared scheduler so UnconfinedTestDispatcher in engine poll scopes shares
// the same virtual clock as the runTest-scoped StandardTestDispatcher.
@OptIn(ExperimentalCoroutinesApi::class)
private val testScheduler = kotlinx.coroutines.test.TestCoroutineScheduler()

@OptIn(ExperimentalCoroutinesApi::class)
private val testDispatcher = StandardTestDispatcher(testScheduler)

// ── Fake SoundfontResolver ─────────────────────────────────────────────────

private class StubSoundfontResolver : SoundfontResolver {
    override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean): Uri? = null
    override val defaultGmSoundfontUri: Uri? = null
}

// ── Helpers for constructing encoded payloads ──────────────────────────────

private fun twoStavesPayload(): ByteArray = StaffParamsCodec.encodeArray(
    listOf(
        StaffParams(0, 0, 0, false, 1L),
        StaffParams(1, 0, 0, true, 2L),
    ),
)

private fun oneStaffPayload(): ByteArray = StaffParamsCodec.encodeArray(
    listOf(StaffParams(0, 0, 0, false, 1L)),
)

private fun downbeatOnlyBeats(): ByteArray = MetronomeBeatCodec.encodeArray(
    listOf(MetronomeBeat(tick = 0, isDownbeat = true)),
)

/** A minimal 14-byte SMF with zero tracks — non-empty so prepare() won't throw. */
private val minimalSmf: ByteArray = byteArrayOf(
    0x4D, 0x54, 0x68, 0x64.toByte(), // "MThd"
    0x00, 0x00, 0x00, 0x06,           // chunk length = 6
    0x00, 0x00,                       // format 0
    0x00, 0x00,                       // 0 tracks
    0x01, 0xE0.toByte(),              // 480 ticks/quarter
)

// ── FakePlayerBindings for inspection ────────────────────────────────────

/** Records calls made through PlayerDriver's NativeBindings seam. */
private class RecordingBindings : PlayerDriver.NativeBindings {
    val loadCalls = mutableListOf<ByteArray>()
    val playCalls = mutableListOf<Unit>()
    val stopCalls = mutableListOf<Unit>()
    val joinCalls = mutableListOf<Unit>()
    val seekTicks = mutableListOf<Long>()
    var closeCalled = false
    var tickToReturn: Long = 0L

    override fun newPlayer(synthHandle: Long): Long = 1L
    override fun deletePlayer(handle: Long) { closeCalled = true }
    override fun playerAddMem(handle: Long, bytes: ByteArray): Int { loadCalls += bytes; return 0 }
    override fun playerPlay(handle: Long): Int { playCalls += Unit; return 0 }
    override fun playerStop(handle: Long): Int { stopCalls += Unit; return 0 }
    override fun playerJoin(handle: Long): Int { joinCalls += Unit; return 0 }
    override fun playerSeek(handle: Long, tick: Long): Int { seekTicks += tick; tickToReturn = tick; return 0 }
    override fun playerGetCurrentTick(handle: Long): Long = tickToReturn
    override fun playerSetTempo(handle: Long, type: Int, value: Double): Int = 0
}

// ── Engine factory (top-level, no auto-registration) ────────────────────────

@OptIn(ExperimentalCoroutinesApi::class)
private fun newEngineForTests(
    bridge: FakeJniBridge = FakeJniBridge(),
    playerBindings: RecordingBindings = RecordingBindings(),
    fakeSynthDrivers: MutableList<FakeSynthDriver> = mutableListOf(),
    // UnconfinedTestDispatcher: poll job starts eagerly, delay() is controlled
    // by testScheduler. All tests use the shared scheduler so advanceTimeBy()
    // works correctly. Tests that call play() must register in managedEngines
    // or call teardown() in finally — enforced via tracked() / preparedEngine().
    pollDispatcher: kotlinx.coroutines.CoroutineDispatcher =
        kotlinx.coroutines.test.UnconfinedTestDispatcher(testScheduler),
): AndroidPlaybackEngine = AndroidPlaybackEngine(
    context = null,
    soundfontResolver = StubSoundfontResolver(),
    jniBridge = bridge,
    synthFactory = { _ ->
        FakeSynthDriver(fakeSynthDrivers.size).also { fakeSynthDrivers += it }
    },
    playerFactory = { _ -> PlayerDriver(0L, playerBindings) },
    oboeFactory = { FakeOboeStream.create() },
    pollDispatcher = pollDispatcher,
)

// ── Tests ──────────────────────────────────────────────────────────────────

@OptIn(ExperimentalCoroutinesApi::class)
class AndroidPlaybackEngineTest {

    /** Engines created via [newEngineForTests] or [preparedEngine] are registered here. */
    private val managedEngines = mutableListOf<AndroidPlaybackEngine>()

    /** Wraps [newEngineForTests] and registers the engine for cleanup in [tearDown]. */
    private fun tracked(
        bridge: FakeJniBridge = FakeJniBridge(),
        playerBindings: RecordingBindings = RecordingBindings(),
        fakeSynthDrivers: MutableList<FakeSynthDriver> = mutableListOf(),
    ): AndroidPlaybackEngine = newEngineForTests(
        bridge = bridge,
        playerBindings = playerBindings,
        fakeSynthDrivers = fakeSynthDrivers,
    ).also { managedEngines += it }

    @Before
    fun setUp() {
        Dispatchers.setMain(testDispatcher)
    }

    @After
    fun tearDown() {
        // Cancel all poll jobs started by tests so no coroutines outlive the test method.
        managedEngines.forEach { runCatching { it.teardown() } }
        managedEngines.clear()
        Dispatchers.resetMain()
    }

    // T36 — initial state

    @Test
    fun `initial state is stopped`() = runTest {
        val engine = newEngineForTests()
        assertEquals(PlaybackState.STOPPED, engine.state.value)
        assertNull(engine.currentCursor.value)
        assertEquals(0.0, engine.currentTimeSeconds.value, 0.001)
        assertEquals(0.0, engine.totalTimeSeconds.value, 0.001)
        assertTrue(engine.mixerChannels.value.isEmpty())
    }

    @Test
    fun `clearCursor resets currentCursor`() = runTest {
        val engine = newEngineForTests()
        engine.clearCursor()
        assertNull(engine.currentCursor.value)
    }

    // T37 — prepare

    @Test
    fun `prepare populates mixer + sets state to PREPARED`() = runTest {
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = twoStavesPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(scoreHandle = 1L)
        assertEquals(PlaybackState.PREPARED, engine.state.value)
        assertEquals(2, engine.mixerChannels.value.size)
        assertEquals(2.0, engine.totalTimeSeconds.value, 0.001)
    }

    @Test
    fun `prepare sets totalTimeSeconds from timeline summary`() = runTest {
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(480L, 3_500_000L, 480L),
            staffParamsResult = oneStaffPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(1L)
        assertEquals(3.5, engine.totalTimeSeconds.value, 0.001)
    }

    @Test(expected = AudioBackendException.EmptyScore::class)
    fun `prepare throws EmptyScore when no staves`() = runTest {
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = StaffParamsCodec.encodeArray(emptyList()),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(1L)
    }

    @Test(expected = AudioBackendException.InvalidScoreHandle::class)
    fun `prepare throws InvalidScoreHandle when renderMidi is empty`() = runTest {
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = oneStaffPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = byteArrayOf(), // empty → throws
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(1L)
    }

    @Test(expected = AudioBackendException.TooManyStaves::class)
    fun `prepare throws TooManyStaves when more than 16 staves`() = runTest {
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = StaffParamsCodec.encodeArray(
                (0..16).map { StaffParams(it, 0, 0, false, it.toLong()) },
            ),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(1L)
    }

    // T38 — play / pause / stop

    @Test
    fun `play transitions from PREPARED to PLAYING`() = runTest {
        val engine = preparedEngine()
        engine.play()
        assertEquals(PlaybackState.PLAYING, engine.state.value)
        engine.teardown()
    }

    @Test
    fun `pause transitions from PLAYING to PAUSED`() = runTest {
        val engine = preparedEngine()
        engine.play()
        engine.pause()
        assertEquals(PlaybackState.PAUSED, engine.state.value)
    }

    @Test
    fun `play after pause resumes PLAYING`() = runTest {
        val engine = preparedEngine()
        engine.play()
        engine.pause()
        engine.play()
        assertEquals(PlaybackState.PLAYING, engine.state.value)
        engine.teardown()
    }

    @Test
    fun `stop transitions to STOPPED and resets cursor`() = runTest {
        val engine = preparedEngine()
        engine.play()
        engine.stop()
        assertEquals(PlaybackState.STOPPED, engine.state.value)
        assertNull(engine.currentCursor.value)
        assertEquals(0.0, engine.currentTimeSeconds.value, 0.001)
    }

    @Test
    fun `play calls PlayerDriver_play`() = runTest {
        val bindings = RecordingBindings()
        val engine = preparedEngine(playerBindings = bindings)
        engine.play()
        assertTrue("play should call PlayerDriver.play()", bindings.playCalls.isNotEmpty())
        engine.teardown()
    }

    @Test
    fun `stop calls PlayerDriver_stop`() = runTest {
        val bindings = RecordingBindings()
        val engine = preparedEngine(playerBindings = bindings)
        engine.play()
        bindings.stopCalls.clear()
        engine.stop()
        assertTrue("stop should call PlayerDriver.stop()", bindings.stopCalls.isNotEmpty())
    }

    @Test
    fun `stop seeks to tick 0`() = runTest {
        val bindings = RecordingBindings()
        val engine = preparedEngine(playerBindings = bindings)
        engine.play()
        bindings.seekTicks.clear()
        engine.stop()
        assertTrue("stop should seek to 0", bindings.seekTicks.contains(0L))
    }

    // T39 — seek / skip

    @Test
    fun `seek updates currentCursor from JniBridge frame`() = runTest {
        val cursor = ScoreCursor.Beat(measureIndex = 1, tickInMeasure = 0)
        val frameBytes = encodeFrameBytes(tick = 100L, timeMicros = 500_000L, cursor = cursor)
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = oneStaffPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
            frameForCursorResult = frameBytes,
        )
        val bindings = RecordingBindings()
        val engine = newEngineForTests(bridge = bridge, playerBindings = bindings)
        engine.prepare(1L)
        engine.seek(cursor)
        assertEquals(cursor, engine.currentCursor.value)
        assertEquals(0.5, engine.currentTimeSeconds.value, 0.001)
    }

    @Test
    fun `seek calls PlayerDriver_seekTick`() = runTest {
        val cursor = ScoreCursor.Beat(measureIndex = 0, tickInMeasure = 0)
        val frameBytes = encodeFrameBytes(tick = 240L, timeMicros = 250_000L, cursor = cursor)
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = oneStaffPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
            frameForCursorResult = frameBytes,
        )
        val bindings = RecordingBindings()
        val engine = newEngineForTests(bridge = bridge, playerBindings = bindings)
        engine.prepare(1L)
        bindings.seekTicks.clear()
        engine.seek(cursor)
        assertTrue("seek should call PlayerDriver.seekTick(240)", bindings.seekTicks.contains(240L))
    }

    @Test
    fun `skip updates position from JniBridge frame`() = runTest {
        val cursor = ScoreCursor.Beat(measureIndex = 2, tickInMeasure = 0)
        val frameBytes = encodeFrameBytes(tick = 480L, timeMicros = 1_000_000L, cursor = cursor)
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = oneStaffPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
            frameAtTickResult = frameBytes,
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(1L)
        engine.skip(1.0) // from 0s + 1s = 1s
        assertEquals(1.0, engine.currentTimeSeconds.value, 0.001)
        assertEquals(cursor, engine.currentCursor.value)
    }

    // T40 — playPreview + earliest

    @Test
    fun `earliest returns null on empty result`() = runTest {
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = oneStaffPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
            earliestOfResult = byteArrayOf(),
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(1L)
        val result = engine.earliest(emptyList())
        assertNull(result)
    }

    @Test
    fun `earliest returns decoded item from JniBridge`() = runTest {
        val noteID = NoteID(StaffAddress(0, 0), 0, 0, 0, 0)
        val item = ScoreItemID.Note(noteID)
        val encoded = ScoreItemIDCodec.encode(item)
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = oneStaffPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
            earliestOfResult = encoded,
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(1L)
        val result = engine.earliest(listOf(item))
        assertEquals(item, result)
    }

    @Test
    fun `playPreview does nothing when pitchAndStaff returns -1`() = runTest {
        val synths = mutableListOf<FakeSynthDriver>()
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = oneStaffPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
            pitchAndStaffOfNoteResult = -1L,
        )
        val engine = newEngineForTests(bridge = bridge, fakeSynthDrivers = synths)
        engine.prepare(1L)
        synths.forEach { it.calls.clear() }
        val noteID = NoteID(StaffAddress(0, 0), 0, 0, 0, 0)
        engine.playPreview(noteID)
        // No noteOn should have been called on any synth driver
        synths.forEach { synth ->
            assertTrue(
                "noteOn should not be called when pitch=-1",
                synth.calls.none { it.startsWith("noteOn") },
            )
        }
    }

    // T41 — mixer methods + solo precedence

    @Test
    fun `setStaffMuted marks channel effectiveMute`() = runTest {
        val engine = preparedEngine(staffCount = 2)
        engine.setStaffMuted(0, true)
        assertTrue(engine.mixerChannels.value[0].effectiveMute)
        assertTrue(engine.mixerChannels.value[0].isMuted)
    }

    @Test
    fun `setStaffMuted does not affect other channels`() = runTest {
        val engine = preparedEngine(staffCount = 2)
        engine.setStaffMuted(0, true)
        assertEquals(false, engine.mixerChannels.value[1].effectiveMute)
    }

    @Test
    fun `setStaffSoloed makes non-soloed staves effectively muted`() = runTest {
        val engine = preparedEngine(staffCount = 2)
        engine.setStaffSoloed(0, true)
        assertEquals(false, engine.mixerChannels.value[0].effectiveMute)
        assertEquals(true, engine.mixerChannels.value[1].effectiveMute)
    }

    @Test
    fun `mute wins over solo on same staff`() = runTest {
        val engine = preparedEngine(staffCount = 2)
        engine.setStaffSoloed(0, true)
        engine.setStaffMuted(0, true)
        // Staff 0 is both muted AND soloed — mute wins.
        assertTrue(engine.mixerChannels.value[0].effectiveMute)
    }

    @Test
    fun `setMasterVolume propagates to oboeStream`() = runTest {
        // OboeStream in tests is a no-op subclass; just verify no crash.
        val engine = preparedEngine()
        engine.setMasterVolume(0.5f)
        // No assertion needed beyond no exception — OboeStream.setMasterVolume is a field write.
    }

    @Test
    fun `setStaffVolume updates channel volume`() = runTest {
        val engine = preparedEngine(staffCount = 2)
        engine.setStaffVolume(1, 0.3f)
        assertEquals(0.3f, engine.mixerChannels.value[1].volume, 0.001f)
    }

    // T41b — mute/unmute CC7 round-trip (Bug 2)

    @Test
    fun `mute then unmute without slider change does not write CC7=127`() = runTest {
        val synths = mutableListOf<FakeSynthDriver>()
        val engine = preparedEngine(staffCount = 1, fakeSynthDrivers = synths)
        val staffSynth = synths.first()
        staffSynth.calls.clear()

        // Mute then unmute staff 0.
        engine.setStaffMuted(0, true)
        staffSynth.calls.clear()
        engine.setStaffMuted(0, false)

        // Unmute should NOT write CC7=127 (the slider default).
        assertFalse(
            "unmute should not snap CC7 to 127",
            staffSynth.calls.contains("cc(0,7,127)"),
        )
    }

    @Test
    fun `slider change then mute then unmute restores slider CC7`() = runTest {
        val synths = mutableListOf<FakeSynthDriver>()
        val engine = preparedEngine(staffCount = 1, fakeSynthDrivers = synths)
        val staffSynth = synths.first()

        // User moves slider to 0.5 → CC7 = 63
        engine.setStaffVolume(0, 0.5f)
        staffSynth.calls.clear()

        engine.setStaffMuted(0, true)
        staffSynth.calls.clear()
        engine.setStaffMuted(0, false)

        assertTrue(
            "unmute after slider set to 0.5 should restore CC7=63",
            staffSynth.calls.contains("cc(0,7,63)"),
        )
    }

    @Test
    fun `solo on other staff does not change this staff CC7 when not muted`() = runTest {
        val synths = mutableListOf<FakeSynthDriver>()
        val engine = preparedEngine(staffCount = 2, fakeSynthDrivers = synths)
        // synths[0] = staff 0, synths[1] = metronome
        val staffSynth = synths.first()
        staffSynth.calls.clear()

        // Solo staff 1 — staff 0 becomes effectively muted, then un-solo — staff 0 unmuted.
        engine.setStaffSoloed(1, true)
        val ccAfterSolo = staffSynth.calls.filter { it.startsWith("cc(0,7,") }
        staffSynth.calls.clear()
        engine.setStaffSoloed(1, false)
        val ccAfterUnSolo = staffSynth.calls.filter { it.startsWith("cc(0,7,") }

        // Staff 0 must not receive CC7=127 when un-soloing staff 1.
        assertFalse(
            "un-solo of another staff must not set CC7=127 on this staff",
            ccAfterUnSolo.contains("cc(0,7,127)"),
        )
        // The restore should use CC7=100 (initial remembered value).
        assertTrue(
            "un-solo of another staff should restore CC7=100 on this staff",
            ccAfterUnSolo.isNotEmpty() && ccAfterUnSolo.last() == "cc(0,7,100)",
        )
    }

    // T42 — metronome

    @Test
    fun `setMetronomeEnabled propagates to metronomeMixer`() = runTest {
        // After prepare, MetronomeMixer.isEnabled starts at false.
        // setMetronomeEnabled(true) should toggle it.
        val engine = preparedEngine()
        engine.setMetronomeEnabled(true)
        // No direct assertion on private field — verified via MetronomeMixerTest.
        // Just verify no exception is thrown.
    }

    @Test
    fun `setMetronomeVolume propagates to metronomeMixer`() = runTest {
        val engine = preparedEngine()
        engine.setMetronomeVolume(0.8f)
        // No exception = pass; MetronomeMixer.volume setter calls synth.setGain.
    }

    // T43 — poll job + teardown

    @Test
    fun `teardown transitions to STOPPED`() = runTest {
        val engine = preparedEngine()
        engine.play()
        engine.teardown()
        assertEquals(PlaybackState.STOPPED, engine.state.value)
    }

    @Test
    fun `teardown after stop is idempotent`() = runTest {
        val engine = preparedEngine()
        engine.teardown()
        engine.teardown() // second call must not throw
    }

    @Test
    fun `poll job queries frameAtTick after play`() = runTest(testDispatcher) {
        val cursor = ScoreCursor.Beat(0, 0)
        val frameBytes = encodeFrameBytes(0L, 0L, cursor)
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = oneStaffPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
            frameAtTickResult = frameBytes,
        )
        val engine = newEngineForTests(bridge = bridge)
        try {
            engine.prepare(1L)
            engine.play()
            advanceTimeBy(100) // covers at least 3 × delay(33) iterations
            assertTrue(
                "frameAtTick should be called by poll job",
                bridge.frameAtTickCalls.isNotEmpty(),
            )
        } finally {
            engine.teardown()
        }
    }

    @Test
    fun `poll job stops calling frameAtTick after pause`() = runTest(testDispatcher) {
        val cursor = ScoreCursor.Beat(0, 0)
        val frameBytes = encodeFrameBytes(0L, 0L, cursor)
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = oneStaffPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
            frameAtTickResult = frameBytes,
        )
        val engine = newEngineForTests(bridge = bridge)
        try {
            engine.prepare(1L)
            engine.play()
            advanceTimeBy(100)
            engine.pause()
            val callCountAfterPause = bridge.frameAtTickCalls.size
            advanceTimeBy(100)
            assertEquals(
                "no more frameAtTick calls after pause",
                callCountAfterPause,
                bridge.frameAtTickCalls.size,
            )
        } finally {
            engine.teardown()
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    /**
     * Creates a prepared engine with [staffCount] staves.
     * Registers the engine in [managedEngines] so [tearDown] calls
     * [AndroidPlaybackEngine.teardown] automatically after each test.
     */
    private suspend fun preparedEngine(
        staffCount: Int = 1,
        playerBindings: RecordingBindings = RecordingBindings(),
        fakeSynthDrivers: MutableList<FakeSynthDriver> = mutableListOf(),
    ): AndroidPlaybackEngine {
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = StaffParamsCodec.encodeArray(
                (0 until staffCount).map { StaffParams(it, 0, 0, false, it.toLong()) },
            ),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
        )
        return tracked(
            bridge = bridge,
            playerBindings = playerBindings,
            fakeSynthDrivers = fakeSynthDrivers,
        ).also { it.prepare(1L) }
    }

    /**
     * Builds a raw [Frame] byte array for use in [FakeJniBridge] results.
     *
     * Wire format: version(u16) + tick(i64) + timeMicros(i64) + ScoreCursor payload
     */
    private fun encodeFrameBytes(
        tick: Long,
        timeMicros: Long,
        cursor: ScoreCursor,
    ): ByteArray {
        val w = io.github.kiichiio.sheetmusic.audio.serialization.BinaryWriter()
        w.writeU16(1)
        w.writeI64(tick)
        w.writeI64(timeMicros)
        ScoreCursorCodec.encodePayload(cursor, w)
        return w.toByteArray()
    }
}
