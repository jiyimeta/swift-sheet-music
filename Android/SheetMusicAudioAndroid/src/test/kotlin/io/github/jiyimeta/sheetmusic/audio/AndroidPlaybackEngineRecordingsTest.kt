package io.github.jiyimeta.sheetmusic.audio

import android.net.Uri
import io.github.jiyimeta.sheetmusic.CountInBeatWire
import io.github.jiyimeta.sheetmusic.CountInWire
import io.github.jiyimeta.sheetmusic.CountInWireCodec
import io.github.jiyimeta.sheetmusic.audio.fakes.FakeJniBridge
import io.github.jiyimeta.sheetmusic.audio.fakes.FakeSynthDriver
import io.github.jiyimeta.sheetmusic.audio.model.Frame
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackAlignment
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackState
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackTimeWarpSpan
import io.github.jiyimeta.sheetmusic.audio.model.RecordingSegment
import io.github.jiyimeta.sheetmusic.audio.model.RecordingTrack
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.audio.model.StaffParams
import io.github.jiyimeta.sheetmusic.audio.serialization.FrameCodec
import io.github.jiyimeta.sheetmusic.audio.serialization.StaffParamsCodec
import io.github.jiyimeta.sheetmusic.audio.synth.CountInTiming
import io.github.jiyimeta.sheetmusic.audio.synth.OboeStream
import io.github.jiyimeta.sheetmusic.audio.synth.PlayerDriver
import io.github.jiyimeta.sheetmusic.audio.synth.SynthDriver
import io.github.jiyimeta.wirelet.BinaryWriter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * A score synth that plays recordings, standing in for `HostedSynth` behind JNI: it records what the engine hands it,
 * keeps a warped clock at half speed (transport tick 480 = 1 s at the fixture's 60 BPM = warped 2 s while an alignment
 * is set), and
 * renders a recognisable mix.
 */
private class RecordingsSynth(val base: FakeSynthDriver = FakeSynthDriver()) : SynthDriver by base {
    val trackCalls = mutableListOf<Triple<List<RecordingTrack>, Boolean, Int>>()
    val alignmentCalls = mutableListOf<PlaybackAlignment>()
    val renderMixCalls = mutableListOf<Pair<SynthDriver?, Boolean>>()
    val prefetchCalls = mutableListOf<Long>()
    val countInCalls = mutableListOf<Double>()
    val transportScores = mutableListOf<Long>()
    var acceptsTracks = true
    var acceptsAlignment = true
    var currentTick = 0L
    private var aligned = false

    override fun setRecordingTracks(tracks: List<RecordingTrack>, soloing: Boolean, readerTransposeSemitones: Int):
        Boolean {
        trackCalls += Triple(tracks, soloing, readerTransposeSemitones)
        return acceptsTracks
    }

    override fun setAlignment(alignment: PlaybackAlignment): Boolean {
        alignmentCalls += alignment
        if (acceptsAlignment) aligned = !alignment.isEmpty
        return acceptsAlignment
    }

    override fun renderMix(
        metronome: SynthDriver?,
        metronomeAudible: Boolean,
        frameCount: Int,
        left: FloatArray,
        right: FloatArray,
        metronomeLeft: FloatArray,
        metronomeRight: FloatArray,
    ): Boolean {
        renderMixCalls += metronome to metronomeAudible
        for (i in 0 until frameCount) {
            left[i] = 0.25f; right[i] = 0.25f
            metronomeLeft[i] = if (metronomeAudible) 0.5f else 0f
            metronomeRight[i] = if (metronomeAudible) 0.5f else 0f
        }
        return true
    }

    private fun warp(seconds: Double) = if (aligned) seconds * 2 else seconds
    override fun currentOutputSeconds(): Double = warp(currentTick / 480.0)
    override fun outputSecondsAtTick(tick: Long): Double = warp(tick / 480.0)
    override fun tickAtOutputSeconds(seconds: Double): Long = ((if (aligned) seconds / 2 else seconds) * 480).toLong()

    // The notated clock: half speed back to the transport, then a repeat's worth (0.25 s) folded off — whatever the
    // synth's own arithmetic, the engine is only to hand it on. The fake answers so even unaligned, so an engine that
    // asked it without an alignment would show.
    override fun setTransportScore(scoreHandle: Long) { transportScores += scoreHandle }
    override fun notatedSecondsAtOutput(seconds: Double): Double = seconds / 2 - 0.25
    override fun outputSecondsAtNotated(seconds: Double): Double = (seconds + 0.25) * 2
    override fun countIn(seconds: Double): CountInTiming {
        countInCalls += seconds
        return CountInTiming(durationSeconds = seconds * 2, speed = 0.5)
    }
    override fun prefetchRecordings(loopStartTick: Long) { prefetchCalls += loopStartTick }
}

/** A stream whose producer a test pulls from. */
private class PullingOboeStream : OboeStream() {
    var pulled: OboeStream.Producer? = null
    override fun setProducer(p: OboeStream.Producer?) { pulled = p; super.setProducer(p) }
    override fun open() {} // and skip AudioTrack construction, as NoOpOboeStream does
    override fun play() {}
    override fun stop() {}
    override fun close() {}
}

@OptIn(ExperimentalCoroutinesApi::class)
class AndroidPlaybackEngineRecordingsTest {
    private val scheduler = TestCoroutineScheduler()
    private val engines = mutableListOf<AndroidPlaybackEngine>()
    private val synths = mutableListOf<RecordingsSynth>()
    private val metronomes = mutableListOf<FakeSynthDriver>()
    private var stream: PullingOboeStream? = null
    private val seeks = mutableListOf<Long>()
    private val tempos = mutableListOf<Double>()
    private var playerTick = 0L

    private val player = object : PlayerDriver.NativeBindings {
        override fun newPlayer(synth: SynthDriver?, bytes: ByteArray) = 1L
        override fun deletePlayer(handle: Long) {}
        override fun playerPlay(handle: Long) {}
        override fun playerStop(handle: Long) {}
        override fun playerSeek(handle: Long, tick: Long) { seeks += tick; playerTick = tick; synths.lastOrNull()?.currentTick = tick }
        override fun playerGetCurrentTick(handle: Long) = playerTick
        override fun playerSetTempo(handle: Long, scale: Double) { tempos += scale }
    }

    private val bridge = FakeJniBridge(
        timelineSummaryResult = longArrayOf(960L, 2_000_000L, 480L),
        staffParamsResult = BinaryWriter().apply {
            writeLengthPrefixed { writeLengthPrefixed { StaffParamsCodec.encodePayload(StaffParams(0, 0, 0, false, 1L), this) } }
        }.toByteArray(),
        renderMidiResult = byteArrayOf(0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 0, 1, 0xE0.toByte()),
        frameAtTickResult = FrameCodec.encode(
            Frame(tick = 480L, timeSeconds = 0.5, cursor = ScoreCursor.Beat(measureIndex = 0, tickInMeasure = 480)),
        ),
    )

    private fun engine(): AndroidPlaybackEngine = AndroidPlaybackEngine(
        context = null,
        soundfontResolver = object : SoundfontResolver {
            override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean): Uri? = null
            override val defaultGmSoundfontUri: Uri? = null
        },
        jniBridge = bridge,
        synthFactory = { _ -> RecordingsSynth().also { synths += it } },
        playerFactory = { _ -> PlayerDriver(null, player) },
        oboeFactory = { PullingOboeStream().also { stream = it } },
        pollDispatcher = UnconfinedTestDispatcher(scheduler),
        metronomeSynthFactory = { _ -> FakeSynthDriver(100).also { metronomes += it } },
    ).also { engines += it }

    private val track = RecordingTrack(id = "vocal", pcmPath = "/cache/vocal-48000.pcm", offsetSeconds = 1.5)
    private val halfSpeed = listOf(PlaybackTimeWarpSpan(start = 0.0, end = 2.0, duration = 4.0))
    private val whole = listOf(RecordingSegment(sourceStart = 0.0, sourceEnd = 60.0, outputStart = 0.0))

    @Before fun setUp() { Dispatchers.setMain(StandardTestDispatcher(scheduler)) }

    @After fun tearDown() {
        engines.forEach { runCatching { it.teardown() } }
        Dispatchers.resetMain()
    }

    @Test fun `tracks and alignment set before a prepare reach the synth it builds`() = runTest(scheduler) {
        val engine = engine()
        engine.setRecordingTracks(listOf(track))
        engine.setAlignment(halfSpeed, whole)
        engine.prepare(1L)
        val synth = synths.single()
        assertEquals(listOf(track), synth.trackCalls.last().first)
        assertEquals(PlaybackAlignment(halfSpeed, whole), synth.alignmentCalls.last())
        assertTrue(engine.hasAlignment)
    }

    @Test fun `with an alignment the total and a skip are on the warped clock`() = runTest(scheduler) {
        val engine = engine()
        engine.prepare(1L)
        assertEquals("notated without one", 2.0, engine.totalTimeSeconds.value, 1e-9)
        engine.setAlignment(halfSpeed, whole)
        assertEquals("the whole sequence at half speed", 4.0, engine.totalTimeSeconds.value, 1e-9)

        engine.seek(toTimeSeconds = 3.0)
        assertEquals("warped 3 s is transport second 1.5, tick 720", 720L, seeks.last())
        assertEquals(3.0, engine.currentTimeSeconds.value, 1e-9)

        engine.setAlignment(emptyList(), emptyList())
        assertFalse(engine.hasAlignment)
        assertEquals(2.0, engine.totalTimeSeconds.value, 1e-9)
    }

    @Test fun `reported and notated seconds are the identity without an alignment and the synth's clock under one`() =
        runTest(scheduler) {
            val engine = engine()
            assertEquals("before a prepare", 3.0, engine.notatedSeconds(3.0), 0.0)
            assertEquals(3.0, engine.reportedSeconds(3.0), 0.0)
            engine.prepare(1L)
            assertEquals("prepared, unaligned", 3.0, engine.notatedSeconds(3.0), 0.0)
            assertEquals(3.0, engine.reportedSeconds(3.0), 0.0)

            engine.setAlignment(halfSpeed, whole)
            assertEquals(1.25, engine.notatedSeconds(3.0), 1e-9)
            assertEquals(3.0, engine.reportedSeconds(1.25), 1e-9)

            engine.setAlignment(emptyList(), emptyList())
            assertEquals("cleared", 3.0, engine.notatedSeconds(3.0), 0.0)
            assertEquals(3.0, engine.reportedSeconds(3.0), 0.0)
        }

    @Test fun `the synth converts over the score its sequence was rendered from, after a prepare and a swap`() =
        runTest(scheduler) {
            bridge.keepsSnapshots = true
            val engine = engine()
            engine.prepare(1L)
            val synth = synths.single()
            assertEquals("the prepared copy, not the host's handle", listOf(100L), synth.transportScores)

            engine.replaceScore(1L)
            assertEquals("the same synth, the swapped-in copy", listOf(100L, 101L), synths.single().transportScores)
        }

    @Test fun `without a copy kept the synth converts over the host's handle`() = runTest(scheduler) {
        val engine = engine()
        engine.prepare(7L)
        assertEquals(listOf(7L), synths.single().transportScores)
    }

    @Test fun `a soloed recording silences the instruments and the bus reaches the synth`() = runTest(scheduler) {
        val engine = engine()
        engine.prepare(1L)
        engine.setRecordingTracks(listOf(track))
        assertFalse(synths.single().trackCalls.last().second)
        engine.setRecordingMix("vocal", volume = 0.5f, isMuted = false, isSoloed = true)
        val (tracks, soloing, _) = synths.single().trackCalls.last()
        assertTrue("the bus is engaged", soloing)
        assertEquals(0.5f, tracks.single().volume)
        assertTrue("the unsoloed instrument goes silent", engine.mixerChannels.value.single().effectiveMute)

        engine.setRecordingMix("vocal", volume = 0.5f, isMuted = false, isSoloed = false)
        engine.setStaffSoloed(partIndex = 0, ordinal = 0, soloed = true)
        assertTrue("an instrument's solo engages the bus for the recordings", synths.single().trackCalls.last().second)
    }

    @Test fun `the reader's transposition reaches the recordings`() = runTest(scheduler) {
        val engine = engine()
        engine.prepare(1L)
        engine.setRecordingTracks(listOf(track.copy(transposeSemitones = 2)))
        engine.setTranspose(-3)
        assertEquals(-3, synths.single().trackCalls.last().third)
    }

    @Test fun `a track list that cannot be mapped throws and leaves the previous one`() = runTest(scheduler) {
        val engine = engine()
        engine.prepare(1L)
        engine.setRecordingTracks(listOf(track))
        synths.single().acceptsTracks = false
        assertThrows(IllegalArgumentException::class.java) {
            engine.setRecordingTracks(listOf(track.copy(id = "other")))
        }
        assertEquals(listOf(track), engine.recordings)
    }

    @Test fun `an invalid warp throws`() = runTest(scheduler) {
        val engine = engine()
        engine.prepare(1L)
        synths.single().acceptsAlignment = false
        assertThrows(IllegalArgumentException::class.java) { engine.setAlignment(halfSpeed, whole) }
        assertFalse(engine.hasAlignment)
    }

    @Test fun `the producer renders the score, its recordings and the click in one call`() = runTest(scheduler) {
        val engine = engine()
        engine.prepare(1L)
        engine.setMetronomeEnabled(true)
        val left = FloatArray(480)
        val right = FloatArray(480)
        stream!!.pulled!!.produce(480, left, right)
        val (metronome, audible) = synths.single().renderMixCalls.single()
        assertTrue("the click synth rides along", metronome === metronomes.single())
        assertTrue(audible)
        assertEquals("score + click", 0.75f, left[0], 1e-6f)
        assertTrue("the fake click synth is not rendered apart", metronomes.single().calls.none { it.startsWith("writeFloat") })
    }

    @Test fun `a count-in under a warp counts at the synth's speed, and the rate comes back after`() = runTest(scheduler) {
        bridge.countInResult = CountInWireCodec.encode(
            CountInWire(
                preRollTicks = 1920, totalSeconds = 2.0,
                beats = listOf(CountInBeatWire(offsetSeconds = 0.0, isDownbeat = true)),
            ),
        )
        bridge.renderCountInMetronomeMidiResult = byteArrayOf(1, 2, 3)
        bridge.renderMetronomeMidiResult = byteArrayOf(4, 5, 6)
        val engine = engine()
        engine.prepare(1L)
        engine.setAlignment(halfSpeed, whole)
        engine.countInEnabled = true
        engine.play()
        assertEquals(listOf(2.0), synths.single().countInCalls)
        assertEquals("the click counts at the measure's warped speed", 0.5, tempos.last(), 1e-9)
        assertEquals(PlaybackState.PLAYING, engine.state.value)
        engine.pause()
        assertEquals("the user's rate after the count", 1.0, tempos.last(), 1e-9)
    }

    @Test fun `prefetch follows a play and a seek`() = runTest(scheduler) {
        val engine = engine()
        engine.prepare(1L)
        engine.setRecordingTracks(listOf(track))
        val before = synths.single().prefetchCalls.size
        engine.seek(toTimeSeconds = 0.5)
        assertTrue(synths.single().prefetchCalls.size > before)
    }
}
