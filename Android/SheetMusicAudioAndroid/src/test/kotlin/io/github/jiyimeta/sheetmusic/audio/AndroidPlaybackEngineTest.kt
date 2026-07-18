package io.github.jiyimeta.sheetmusic.audio

import android.net.Uri
import io.github.jiyimeta.sheetmusic.audio.export.AudioExporter
import io.github.jiyimeta.sheetmusic.audio.export.fakes.FakeAudioFileEncoder
import io.github.jiyimeta.sheetmusic.audio.fakes.FakeJniBridge
import io.github.jiyimeta.sheetmusic.audio.fakes.FakeOboeStream
import io.github.jiyimeta.sheetmusic.audio.fakes.FakePlayerDriver
import io.github.jiyimeta.sheetmusic.audio.fakes.FakeSynthDriver
import io.github.jiyimeta.sheetmusic.audio.model.AudioExportRange
import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat
import io.github.jiyimeta.sheetmusic.audio.model.MetronomeBeat
import io.github.jiyimeta.sheetmusic.audio.model.NoteID
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.model.StaffAddress
import io.github.jiyimeta.sheetmusic.audio.model.StaffParams
import io.github.jiyimeta.wirelet.BinaryWriter
import io.github.jiyimeta.sheetmusic.audio.model.Frame
import io.github.jiyimeta.sheetmusic.audio.serialization.FrameCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.MetronomeBeatCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.NoteIDCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreCursorCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.ScoreItemIDCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.StaffParamsCodec
import io.github.jiyimeta.sheetmusic.audio.synth.OboeStream
import io.github.jiyimeta.sheetmusic.audio.synth.PlayerDriver
import io.github.jiyimeta.sheetmusic.audio.synth.SynthDriver
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

private fun encodeStaffParamsArray(params: List<StaffParams>): ByteArray {
    val w = BinaryWriter()
    w.writeLengthPrefixed {
        for (p in params) writeLengthPrefixed { StaffParamsCodec.encodePayload(p, this) }
    }
    return w.toByteArray()
}

private fun encodeMetronomeBeatArray(beats: List<MetronomeBeat>): ByteArray {
    val w = BinaryWriter()
    w.writeLengthPrefixed {
        for (b in beats) writeLengthPrefixed { MetronomeBeatCodec.encodePayload(b, this) }
    }
    return w.toByteArray()
}

private fun twoStavesPayload(): ByteArray = encodeStaffParamsArray(
    listOf(
        StaffParams(0, 0, 0, false, 1L),
        StaffParams(1, 0, 0, true, 2L),
    ),
)

private fun oneStaffPayload(): ByteArray = encodeStaffParamsArray(
    listOf(StaffParams(0, 0, 0, false, 1L)),
)

private fun downbeatOnlyBeats(): ByteArray = encodeMetronomeBeatArray(
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

// ── Recording OboeStream for inspection ──────────────────────────────────

/**
 * [OboeStream] subclass that records play/stop invocation counts.
 *
 * Mirrors [NoOpOboeStream] (no AudioTrack is ever constructed) but counts
 * [play] / [stop] so tests can assert the audio output driver is started for
 * a preview and restored afterward. Counters are [java.util.concurrent.atomic.AtomicInteger]
 * because [stop] may be invoked from the preview drain coroutine.
 */
internal class RecordingOboeStream : OboeStream() {
    val playCount = java.util.concurrent.atomic.AtomicInteger(0)
    val stopCount = java.util.concurrent.atomic.AtomicInteger(0)
    override fun open() { /* skip AudioTrack construction */ }
    override fun play() { playCount.incrementAndGet() }
    override fun stop() { stopCount.incrementAndGet() }
    override fun close() { /* no-op */ }
}

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
    val setTempoCalls = mutableListOf<Pair<Int, Double>>()
    override fun playerSetTempo(handle: Long, type: Int, value: Double): Int {
        setTempoCalls += type to value
        return 0
    }
}

// ── Engine factory (top-level, no auto-registration) ────────────────────────

@OptIn(ExperimentalCoroutinesApi::class)
private fun newEngineForTests(
    bridge: FakeJniBridge = FakeJniBridge(),
    playerBindings: RecordingBindings = RecordingBindings(),
    fakeSynthDrivers: MutableList<FakeSynthDriver> = mutableListOf(),
    metronomeClickProvider: MetronomeClickProvider? = null,
    // UnconfinedTestDispatcher: poll job starts eagerly, delay() is controlled
    // by testScheduler. All tests use the shared scheduler so advanceTimeBy()
    // works correctly. Tests that call play() must register in managedEngines
    // or call teardown() in finally — enforced via tracked() / preparedEngine().
    pollDispatcher: kotlinx.coroutines.CoroutineDispatcher =
        kotlinx.coroutines.test.UnconfinedTestDispatcher(testScheduler),
    oboeFactory: () -> OboeStream = { FakeOboeStream.create() },
): AndroidPlaybackEngine = AndroidPlaybackEngine(
    context = null,
    soundfontResolver = StubSoundfontResolver(),
    metronomeClickProvider = metronomeClickProvider,
    jniBridge = bridge,
    synthFactory = { _ ->
        FakeSynthDriver(fakeSynthDrivers.size).also { fakeSynthDrivers += it }
    },
    playerFactory = { _ -> PlayerDriver(0L, playerBindings) },
    oboeFactory = oboeFactory,
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
            staffParamsResult = encodeStaffParamsArray(emptyList()),
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
            staffParamsResult = encodeStaffParamsArray(
                (0..16).map { StaffParams(it, 0, 0, false, it.toLong()) },
            ),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(1L)
    }

    @Test
    fun `prepare with click provider calls buildClickSoundFont on bridge`() = runTest {
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = oneStaffPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
        ).apply {
            buildClickSoundFontResult = byteArrayOf(1, 2, 3)
        }
        val engine = newEngineForTests(
            bridge = bridge,
            metronomeClickProvider = MetronomeClickProvider {
                MetronomeClickSource.ClickSamples(byteArrayOf(9), byteArrayOf(8))
            },
        )
        engine.prepare(scoreHandle = 1L)
        assertEquals(1, bridge.buildClickSoundFontCalls.size)
        engine.teardown()
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

    @Test
    fun `seekToTimeSeconds updates position to absolute time`() = runTest {
        // Set up a frameAtTickResult corresponding to target=2.0s (out of total=2.0s).
        // skip()'s tick estimate at target=2.0 / total=2.0 * totalTicks=960 = 960L.
        val cursor = ScoreCursor.Beat(measureIndex = 3, tickInMeasure = 0)
        val frameBytes = encodeFrameBytes(tick = 960L, timeMicros = 2_000_000L, cursor = cursor)
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = oneStaffPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
            frameAtTickResult = frameBytes,
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(1L)
        engine.seek(toTimeSeconds = 2.0)
        assertEquals(2.0, engine.currentTimeSeconds.value, 0.001)
        assertEquals(cursor, engine.currentCursor.value)
    }

    @Test
    fun `seekToTimeSeconds clamps to totalTimeSeconds`() = runTest {
        // Target way beyond end: should clamp to total (2.0s) and call skip
        // with delta = (2.0 - 0.0).
        val cursor = ScoreCursor.Beat(measureIndex = 3, tickInMeasure = 0)
        val frameBytes = encodeFrameBytes(tick = 960L, timeMicros = 2_000_000L, cursor = cursor)
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = oneStaffPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
            frameAtTickResult = frameBytes,
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(1L)
        engine.seek(toTimeSeconds = 999.0)
        assertEquals(2.0, engine.currentTimeSeconds.value, 0.001)
    }

    @Test
    fun `seekToTimeSeconds clamps to zero on negative target`() = runTest {
        val cursor = ScoreCursor.Beat(measureIndex = 0, tickInMeasure = 0)
        val frameBytes = encodeFrameBytes(tick = 0L, timeMicros = 0L, cursor = cursor)
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = oneStaffPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
            frameAtTickResult = frameBytes,
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(1L)
        engine.seek(toTimeSeconds = -10.0)
        assertEquals(0.0, engine.currentTimeSeconds.value, 0.001)
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

    // T40b — playPreview starts/restores the Oboe output stream (Bug: silent preview)

    private fun previewBridge(): FakeJniBridge = FakeJniBridge(
        timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
        staffParamsResult = oneStaffPayload(),
        metronomeBeatsResult = downbeatOnlyBeats(),
        renderMidiResult = minimalSmf,
        // Valid packed value: pitch 67 in high 32 bits, staffIndex 0 in low.
        pitchAndStaffOfNoteResult = (67L shl 32) or 0L,
    )

    @Test
    fun `preview while not playing starts the audio stream then restores it stopped`() =
        runTest(testDispatcher) {
            val oboe = RecordingOboeStream()
            val engine = newEngineForTests(bridge = previewBridge(), oboeFactory = { oboe })
                .also { managedEngines += it }
            engine.prepare(1L)
            // state == PREPARED; not playing.
            val playBefore = oboe.playCount.get()
            val stopBefore = oboe.stopCount.get()

            val noteID = NoteID(StaffAddress(0, 0), 0, 0, 0, 0)
            engine.playPreview(noteID, durationMillis = 50)

            assertTrue(
                "preview must START the audio stream so the queued note is audible",
                oboe.playCount.get() > playBefore,
            )

            advanceTimeBy(50 + 20)
            testScheduler.runCurrent()

            assertTrue(
                "preview must STOP (restore) the audio stream after the note drains, " +
                    "since we were not playing",
                oboe.stopCount.get() > stopBefore,
            )
        }

    @Test
    fun `preview while playing does not stop the stream on drain`() = runTest(testDispatcher) {
        val oboe = RecordingOboeStream()
        val engine = newEngineForTests(bridge = previewBridge(), oboeFactory = { oboe })
            .also { managedEngines += it }
        engine.prepare(1L)
        engine.play() // state == PLAYING, stream running
        val stopBefore = oboe.stopCount.get()

        val noteID = NoteID(StaffAddress(0, 0), 0, 0, 0, 0)
        engine.playPreview(noteID, durationMillis = 50)

        advanceTimeBy(50 + 20)
        testScheduler.runCurrent()

        assertEquals(
            "preview must NOT stop the stream while playing — playback keeps running",
            stopBefore,
            oboe.stopCount.get(),
        )
        engine.teardown()
    }

    @Test
    fun `overlapping previews only stop the stream once after both drain`() =
        runTest(testDispatcher) {
            val oboe = RecordingOboeStream()
            val engine = newEngineForTests(bridge = previewBridge(), oboeFactory = { oboe })
                .also { managedEngines += it }
            engine.prepare(1L)
            val stopBefore = oboe.stopCount.get()

            val noteID = NoteID(StaffAddress(0, 0), 0, 0, 0, 0)
            // Two overlapping previews before the first drains.
            engine.playPreview(noteID, durationMillis = 50)
            engine.playPreview(noteID, durationMillis = 50)

            advanceTimeBy(50 + 20)
            testScheduler.runCurrent()

            assertEquals(
                "two overlapping previews must produce exactly ONE stop after both drain",
                stopBefore + 1,
                oboe.stopCount.get(),
            )
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

    // End-of-score against the UNROLLED length (repeats / jumps)

    @Test
    fun `poll job does not stop early when unrolled length exceeds notated total`() =
        runTest(testDispatcher) {
            // Notated total 960, but the repeat/jump-expanded SMF the player
            // traverses runs to 1920 (summary[3]). A player tick of 1000 is
            // past the notated total yet still mid-piece — playback must NOT
            // stop. Under the old `tick >= totalTicks` check it stopped here.
            val cursor = ScoreCursor.Beat(0, 0)
            val frameBytes = encodeFrameBytes(0L, 0L, cursor)
            val bridge = FakeJniBridge(
                timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L, 1920L),
                staffParamsResult = oneStaffPayload(),
                metronomeBeatsResult = downbeatOnlyBeats(),
                renderMidiResult = minimalSmf,
                frameAtTickResult = frameBytes,
            )
            val bindings = RecordingBindings()
            val engine = newEngineForTests(bridge = bridge, playerBindings = bindings)
            try {
                engine.prepare(1L)
                engine.play()
                // Set after play() so a seek-to-start during play can't reset it.
                bindings.tickToReturn = 1000L
                advanceTimeBy(100) // several poll iterations past the notated total
                assertEquals(
                    "playback must continue past the notated total during a repeat",
                    PlaybackState.PLAYING,
                    engine.state.value,
                )
            } finally {
                engine.teardown()
            }
        }

    @Test
    fun `poll job stops at the unrolled end of score`() = runTest(testDispatcher) {
        val cursor = ScoreCursor.Beat(0, 0)
        val frameBytes = encodeFrameBytes(0L, 0L, cursor)
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L, 1920L),
            staffParamsResult = oneStaffPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
            frameAtTickResult = frameBytes,
        )
        val bindings = RecordingBindings()
        val engine = newEngineForTests(bridge = bridge, playerBindings = bindings)
        try {
            engine.prepare(1L)
            engine.play()
            bindings.tickToReturn = 1920L // reached the unrolled end
            advanceTimeBy(100)
            assertEquals(
                "playback stops when the player reaches the unrolled end",
                PlaybackState.STOPPED,
                engine.state.value,
            )
        } finally {
            engine.teardown()
        }
    }

    // T44 — setRate / currentRate

    @Test
    fun `setRate forwards to player`() = runTest(testDispatcher) {
        val bindings = RecordingBindings()
        val bridge = FakeJniBridge(
            staffParamsResult = oneStaffPayload(),
            renderMidiResult = minimalSmf,
            metronomeBeatsResult = downbeatOnlyBeats(),
        )
        val engine = newEngineForTests(bridge = bridge, playerBindings = bindings)
        engine.prepare(scoreHandle = 1L)
        bindings.setTempoCalls.clear()

        engine.setRate(1.5f)

        assertEquals(1, bindings.setTempoCalls.size)
        assertEquals(1.5, bindings.setTempoCalls.first().second, 0.0001)
        assertEquals(1.5f, engine.currentRate.value, 0.0001f)
        engine.teardown()
    }

    @Test
    fun `setRate before prepare is recorded and reapplied at prepare`() = runTest(testDispatcher) {
        val bindings = RecordingBindings()
        val bridge = FakeJniBridge(
            staffParamsResult = oneStaffPayload(),
            renderMidiResult = minimalSmf,
            metronomeBeatsResult = downbeatOnlyBeats(),
        )
        val engine = newEngineForTests(bridge = bridge, playerBindings = bindings)

        engine.setRate(0.5f)
        // No player yet — no call recorded.
        assertEquals(0, bindings.setTempoCalls.size)

        engine.prepare(scoreHandle = 1L)

        // After prepare the pending rate must be re-applied to the new player.
        assertEquals(1, bindings.setTempoCalls.size)
        assertEquals(0.5, bindings.setTempoCalls.first().second, 0.0001)
        engine.teardown()
    }

    @Test
    fun `currentRate stateflow updates`() = runTest(testDispatcher) {
        val bindings = RecordingBindings()
        val bridge = FakeJniBridge(
            staffParamsResult = oneStaffPayload(),
            renderMidiResult = minimalSmf,
            metronomeBeatsResult = downbeatOnlyBeats(),
        )
        val engine = newEngineForTests(bridge = bridge, playerBindings = bindings)
        engine.prepare(scoreHandle = 1L)
        assertEquals(1.0f, engine.currentRate.value, 0.0001f)

        engine.setRate(2.0f)
        assertEquals(2.0f, engine.currentRate.value, 0.0001f)
        engine.teardown()
    }

    // T5C — setStaffProgram + MixerChannel.program init

    @Test
    fun `prepare sets initial program from StaffParams`() = runTest(testDispatcher) {
        val payload = encodeStaffParamsArray(
            listOf(StaffParams(0, 0, 24, false, 1L)),  // acoustic guitar nylon
        )
        val bridge = FakeJniBridge(
            staffParamsResult = payload,
            renderMidiResult = minimalSmf,
            metronomeBeatsResult = downbeatOnlyBeats(),
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(scoreHandle = 1L)

        assertEquals(24, engine.mixerChannels.value[0].program)
        engine.teardown()
    }

    @Test
    fun `prepare sets null program for drum staff`() = runTest(testDispatcher) {
        val payload = encodeStaffParamsArray(
            listOf(StaffParams(0, 0, 0, isDrums = true, partAddressHash = 1L)),
        )
        val bridge = FakeJniBridge(
            staffParamsResult = payload,
            renderMidiResult = minimalSmf,
            metronomeBeatsResult = downbeatOnlyBeats(),
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(scoreHandle = 1L)

        assertNull(engine.mixerChannels.value[0].program)
        engine.teardown()
    }

    @Test
    fun `setStaffProgram updates mixer and synth`() = runTest(testDispatcher) {
        val payload = encodeStaffParamsArray(
            listOf(StaffParams(0, 0, 0, false, 1L)),
        )
        val bridge = FakeJniBridge(
            staffParamsResult = payload,
            renderMidiResult = minimalSmf,
            metronomeBeatsResult = downbeatOnlyBeats(),
        )
        val synthDrivers = mutableListOf<FakeSynthDriver>()
        val engine = newEngineForTests(bridge = bridge, fakeSynthDrivers = synthDrivers)
        engine.prepare(scoreHandle = 1L)

        // The staff synth is the first one captured (the metronome synth is
        // created later in prepare and is a separate driver — confirm by
        // checking either index 0 or by selecting the one with handleValue
        // matching the staff sample rate). For this test the staff synth is
        // the first one captured.
        val staffSynth = synthDrivers.first()
        staffSynth.calls.clear()

        engine.setStaffProgram(0, 40)  // violin

        assertEquals(40, engine.mixerChannels.value[0].program)
        // The setStaffProgram path calls programSelect on the synth.
        // FakeSynthDriver records as "programSelect(sfid,channel,bank,program)".
        // sfid is what FakeSynthDriver returned from loadSoundFont — default 0.
        assertTrue(
            "expected programSelect with program=40 in synth.calls; got ${staffSynth.calls}",
            staffSynth.calls.any { it.startsWith("programSelect(") && it.endsWith(",40)") },
        )
        engine.teardown()
    }

    // T5D — setLoop / clearLoop

    private fun cursorAt(elementIndex: Int) = ScoreCursor.Beat(
        measureIndex = elementIndex,
        tickInMeasure = 0,
    )

    private fun frameAt(tick: Long, elementIndex: Int): ByteArray =
        encodeFrameBytes(tick = tick, timeMicros = tick * 1000L, cursor = cursorAt(elementIndex))

    @Test
    fun `setLoop fromTo stores LoopRange when frames resolve`() = runTest(testDispatcher) {
        val frame100 = frameAt(100L, 0)
        val frame200 = frameAt(200L, 1)
        val frames = listOf(frame100, frame200)
        var nextIdx = 0
        val bridge = object : FakeJniBridge(
            staffParamsResult = oneStaffPayload(),
            renderMidiResult = minimalSmf,
            metronomeBeatsResult = downbeatOnlyBeats(),
        ) {
            override fun frameForCursor(scoreHandle: Long, cursorBytes: ByteArray): ByteArray {
                val out = frames[nextIdx % frames.size]; nextIdx++
                return out
            }
        }
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(scoreHandle = 1L)
        engine.setLoop(from = cursorAt(0), to = cursorAt(1))
        val lr = engine.loopRange.value
        assertNotNull(lr)
        assertEquals(100L, lr!!.startTick)
        assertEquals(200L, lr.endTick)
        engine.teardown()
    }

    @Test
    fun `setLoop fromTo invalid range is no-op`() = runTest(testDispatcher) {
        // Same frame for both cursors → 100 >= 100, no-op.
        val frame100 = frameAt(100L, 0)
        val bridge = FakeJniBridge(
            staffParamsResult = oneStaffPayload(),
            renderMidiResult = minimalSmf,
            metronomeBeatsResult = downbeatOnlyBeats(),
            frameForCursorResult = frame100,
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(scoreHandle = 1L)
        engine.setLoop(from = cursorAt(0), to = cursorAt(0))
        assertNull(engine.loopRange.value)
        engine.teardown()
    }

    @Test
    fun `clearLoop resets range`() = runTest(testDispatcher) {
        val frame100 = frameAt(100L, 0)
        val frame200 = frameAt(200L, 1)
        val frames = listOf(frame100, frame200)
        var nextIdx = 0
        val bridge = object : FakeJniBridge(
            staffParamsResult = oneStaffPayload(),
            renderMidiResult = minimalSmf,
            metronomeBeatsResult = downbeatOnlyBeats(),
        ) {
            override fun frameForCursor(scoreHandle: Long, cursorBytes: ByteArray): ByteArray {
                val out = frames[nextIdx % frames.size]; nextIdx++
                return out
            }
        }
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(scoreHandle = 1L)
        engine.setLoop(from = cursorAt(0), to = cursorAt(1))
        assertNotNull(engine.loopRange.value)
        engine.clearLoop()
        assertNull(engine.loopRange.value)
        engine.teardown()
    }

    @Test
    fun `setLoop throughEndOf uses itemEndTick`() = runTest(testDispatcher) {
        val frame100 = frameAt(100L, 0)
        val bridge = FakeJniBridge(
            staffParamsResult = oneStaffPayload(),
            renderMidiResult = minimalSmf,
            metronomeBeatsResult = downbeatOnlyBeats(),
            frameForCursorResult = frame100,
            itemEndTickResult = 300L,
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(scoreHandle = 1L)
        val rid = io.github.jiyimeta.sheetmusic.audio.model.RestID(
            staff = StaffAddress(0, 0),
            measureIndex = 0, voiceIndex = 0, elementIndex = 1,
        )
        engine.setLoop(from = cursorAt(0), throughEndOf = ScoreItemID.Rest(rid))
        val lr = engine.loopRange.value
        assertNotNull(lr)
        assertEquals(100L, lr!!.startTick)
        assertEquals(300L, lr.endTick)
        engine.teardown()
    }

    @Test
    fun `setLoop throughEndOf is no-op when item unknown`() = runTest(testDispatcher) {
        val frame100 = frameAt(100L, 0)
        val bridge = FakeJniBridge(
            staffParamsResult = oneStaffPayload(),
            renderMidiResult = minimalSmf,
            metronomeBeatsResult = downbeatOnlyBeats(),
            frameForCursorResult = frame100,
            itemEndTickResult = -1L,
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(scoreHandle = 1L)
        val rid = io.github.jiyimeta.sheetmusic.audio.model.RestID(
            staff = StaffAddress(0, 0),
            measureIndex = 0, voiceIndex = 0, elementIndex = 1,
        )
        engine.setLoop(from = cursorAt(0), throughEndOf = ScoreItemID.Rest(rid))
        assertNull(engine.loopRange.value)
        engine.teardown()
    }

    @Test
    fun `prepare clears loop range`() = runTest(testDispatcher) {
        val frame100 = frameAt(100L, 0)
        val bridge = FakeJniBridge(
            staffParamsResult = oneStaffPayload(),
            renderMidiResult = minimalSmf,
            metronomeBeatsResult = downbeatOnlyBeats(),
            frameForCursorResult = frame100,
            itemEndTickResult = 300L,
        )
        val engine = newEngineForTests(bridge = bridge)
        engine.prepare(scoreHandle = 1L)
        val rid = io.github.jiyimeta.sheetmusic.audio.model.RestID(
            staff = StaffAddress(0, 0),
            measureIndex = 0, voiceIndex = 0, elementIndex = 1,
        )
        engine.setLoop(from = cursorAt(0), throughEndOf = ScoreItemID.Rest(rid))
        assertNotNull(engine.loopRange.value)
        engine.prepare(scoreHandle = 2L)
        assertNull(engine.loopRange.value)
        engine.teardown()
    }

    // T5E — setLoopMeasures / setLoopFullScore

    /**
     * Bridge whose `frameForCursor` resolves `Beat(m, 0)` to `tick = m * 480` for
     * `m in 0 until measureCount`, and returns empty bytes for any measure beyond the score
     * (so the last-measure fallback path in [AndroidPlaybackEngine.setLoopMeasures] is exercised).
     * `timelineSummary` reports `totalTicks = measureCount * 480`.
     */
    private fun measureLoopBridge(measureCount: Int): FakeJniBridge =
        object : FakeJniBridge(
            timelineSummaryResult = longArrayOf(measureCount * 480L, 2_000_000L, 480L),
            staffParamsResult = oneStaffPayload(),
            renderMidiResult = minimalSmf,
            metronomeBeatsResult = downbeatOnlyBeats(),
        ) {
            override fun frameForCursor(scoreHandle: Long, cursorBytes: ByteArray): ByteArray {
                val cursor = ScoreCursorCodec.decode(cursorBytes) as? ScoreCursor.Beat
                    ?: return byteArrayOf()
                val m = cursor.measureIndex
                return if (m in 0 until measureCount) {
                    encodeFrameBytes(tick = m * 480L, timeMicros = m * 480L * 1000L, cursor = cursor)
                } else {
                    byteArrayOf()
                }
            }
        }

    @Test
    fun `setLoopMeasures loops interior measures`() = runTest(testDispatcher) {
        val engine = newEngineForTests(bridge = measureLoopBridge(measureCount = 4))
        engine.prepare(scoreHandle = 1L)
        engine.setLoopMeasures(fromMeasure = 1, toMeasure = 2)
        val lr = engine.loopRange.value
        assertNotNull(lr)
        assertEquals(480L, lr!!.startTick)
        assertEquals(1440L, lr.endTick)
        engine.teardown()
    }

    @Test
    fun `setLoopMeasures on last measure ends at totalTicks`() = runTest(testDispatcher) {
        val engine = newEngineForTests(bridge = measureLoopBridge(measureCount = 4))
        engine.prepare(scoreHandle = 1L)
        // Beat(4, 0) does not resolve (measures 0..3 exist) → fall back to totalTicks = 1920.
        engine.setLoopMeasures(fromMeasure = 3, toMeasure = 3)
        val lr = engine.loopRange.value
        assertNotNull(lr)
        assertEquals(1440L, lr!!.startTick)
        assertEquals(1920L, lr.endTick)
        engine.teardown()
    }

    @Test
    fun `setLoopFullScore loops zero to totalTicks`() = runTest(testDispatcher) {
        val engine = newEngineForTests(bridge = measureLoopBridge(measureCount = 4))
        engine.prepare(scoreHandle = 1L)
        engine.setLoopFullScore()
        val lr = engine.loopRange.value
        assertNotNull(lr)
        assertEquals(0L, lr!!.startTick)
        assertEquals(1920L, lr.endTick)
        engine.teardown()
    }

    @Test
    fun `setLoopMeasures is no-op when start does not resolve`() = runTest(testDispatcher) {
        val engine = newEngineForTests(bridge = measureLoopBridge(measureCount = 4))
        engine.prepare(scoreHandle = 1L)
        engine.setLoopMeasures(fromMeasure = 9, toMeasure = 9) // start beyond score
        assertNull(engine.loopRange.value)
        engine.teardown()
    }

    // T14 — exportAudioFile

    @Test(expected = AudioBackendException.NoScorePrepared::class)
    fun `exportAudioFile throws NoScorePrepared when handle does not match`() = runTest {
        // No prepare() called — scoreHandle = 0.
        val engine = tracked()
        engine.exportAudioFileWith(
            outputFd = null,
            scoreHandle = 999L,
            format = AudioFileFormat.Wav(),
            range = AudioExportRange.Full,
            progress = null,
            exporterFactory = { error("must not be invoked") },
        )
    }

    @Test
    fun `exportAudioFile flips state to EXPORTING then back to STOPPED`() = runTest {
        // endTick = 0 so the while (currentTick < endTick) loop never enters
        // and the run completes synchronously without needing tick advance.
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = oneStaffPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
            resolveExportTickRangeResult = longArrayOf(0L, 0L),
        )
        val engine = tracked(bridge = bridge)
        engine.prepare(1L)

        // Capture the state observed inside the export pipeline so the test
        // doesn't need to race a collector against the mutex.
        var stateDuringRun: PlaybackState? = null
        val encoder = FakeAudioFileEncoder()
        val (player, _) = FakePlayerDriver.create()
        val synth = FakeSynthDriver()

        val exporter = AudioExporter(
            resolver = StubSoundfontResolver(),
            context = null,
            synthFactory = { _ ->
                stateDuringRun = engine.state.value
                synth
            },
            playerFactory = { _ -> player },
            encoderFactory = { _, _, _ -> encoder },
        )

        engine.exportAudioFileWith(
            outputFd = null,
            scoreHandle = 1L,
            format = AudioFileFormat.Wav(),
            range = AudioExportRange.Full,
            progress = null,
            exporterFactory = { exporter },
        )

        assertEquals(PlaybackState.EXPORTING, stateDuringRun)
        assertEquals(PlaybackState.STOPPED, engine.state.value)
        assertTrue("encoder.finish() should have been called", encoder.finished)
    }

    @Test(expected = AudioBackendException.RangeNotInTimeline::class)
    fun `exportAudioFile throws RangeNotInTimeline when JNI returns -1`() = runTest {
        val bridge = FakeJniBridge(
            timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
            staffParamsResult = oneStaffPayload(),
            metronomeBeatsResult = downbeatOnlyBeats(),
            renderMidiResult = minimalSmf,
            resolveExportTickRangeResult = longArrayOf(-1L, -1L),
        )
        val engine = tracked(bridge = bridge)
        engine.prepare(1L)
        engine.exportAudioFileWith(
            outputFd = null,
            scoreHandle = 1L,
            format = AudioFileFormat.Wav(),
            range = AudioExportRange.Full,
            progress = null,
            exporterFactory = { error("must not be invoked") },
        )
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
            staffParamsResult = encodeStaffParamsArray(
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
     * Builds a [Frame] byte array (wirelet TLV format) for use in [FakeJniBridge] results.
     *
     * Uses [FrameCodec.encode] to produce bytes in the same TLV format that
     * the Swift JNI bridge sends across the boundary.
     */
    private fun encodeFrameBytes(
        tick: Long,
        timeMicros: Long,
        cursor: ScoreCursor,
    ): ByteArray = FrameCodec.encode(
        Frame(
            tick = tick,
            timeSeconds = timeMicros.toDouble() / 1_000_000.0,
            cursor = cursor,
        ),
    )
}
