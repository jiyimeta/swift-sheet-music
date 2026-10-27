package io.github.jiyimeta.sheetmusic.audio.export

import android.net.Uri
import io.github.jiyimeta.sheetmusic.audio.SoundfontResolver
import io.github.jiyimeta.sheetmusic.audio.export.fakes.FakeAudioFileEncoder
import io.github.jiyimeta.sheetmusic.audio.fakes.FakePlayerDriver
import io.github.jiyimeta.sheetmusic.audio.fakes.FakeSynthDriver
import io.github.jiyimeta.sheetmusic.audio.fakes.MarkerMasterTuning
import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat
import io.github.jiyimeta.sheetmusic.audio.model.InstrumentParams
import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel
import io.github.jiyimeta.sheetmusic.audio.synth.AndroidMetronomeClickResolver
import io.github.jiyimeta.sheetmusic.audio.synth.PlayerDriver
import io.github.jiyimeta.sheetmusic.audio.synth.SynthDriver
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * An export that counts in puts the count live playback plays from the same start ahead of the music: the count-in
 * click sequence on the metronome's transport, with the score player held for exactly the pre-roll's length of
 * output. Live playback hands over when the click transport reaches the pre-roll's last tick, which it polls for; an
 * offline render has no wall clock to poll, so the handover here is a frame count.
 */
class AudioExporterCountInTest {

    // ── Stubs ────────────────────────────────────────────────────────────────

    private class StubSoundfontResolver : SoundfontResolver {
        override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean): Uri? = null
        override val defaultGmSoundfontUri: Uri? = null
    }

    // ── Fixtures ─────────────────────────────────────────────────────────────

    private val strips = listOf(
        InstrumentParams(
            partIndex = 0, ordinal = 0, liveChannel = 0,
            bankLSB = 0, program = 0, isDrums = false, displayName = "Staff 1",
        ),
    )

    /** The body's plain click sequence, which a count-in replaces with [countInSmf]. */
    private val bodyClicks = byteArrayOf(1, 2, 3, 4)

    /** The count-in click sequence: the pre-roll region in front, the body's clicks shifted behind it. */
    private val countInSmf = byteArrayOf(7, 7)

    /** A one-second pre-roll on the sequence clock. */
    private val oneSecondCount = CountInExport(metronomeSmfBytes = countInSmf, preRollSeconds = 1.0)

    private fun snapshot(metronomeEnabled: Boolean = false, rate: Float = 1.0f) = ExportEngineSnapshot(
        mixerChannels = listOf(
            MixerChannel(partIndex = 0, ordinal = 0, liveChannel = 0, displayName = "Staff 1", program = 0),
        ),
        metronomeEnabled = metronomeEnabled,
        metronomeVolume = 1.0f,
        metronomeSmfBytes = bodyClicks,
        rate = rate,
        metronomeResolution = AndroidMetronomeClickResolver.Resolution.DefaultGm,
    )

    /** What one render did, as the fakes saw it. */
    private class Render(
        val synthsBuilt: Int,
        /** Frames the score synth rendered before the score player was started. */
        val framesBeforeScorePlay: Int,
        val scorePlayCalls: Int,
        /** The metronome player's recorded calls. */
        val metronome: FakePlayerDriver.RecordingBindings,
        /** Every frame the metronome synth was asked to render. */
        val metronomeFrames: Int,
    )

    /**
     * Runs an export from tick 0 to 960 at 48 kHz. The score synth (the first one built) counts the frames it renders
     * while the score player has not been started, and once it has, advances the player 240 ticks per block so the
     * render loop ends. The metronome's synth and player (the second of each) only record.
     */
    private suspend fun render(snapshot: ExportEngineSnapshot, countIn: CountInExport?): Render {
        val createdSynths = mutableListOf<FakeSynthDriver>()
        val (scorePlayer, scoreBindings) = FakePlayerDriver.create()
        val metronomeBindings = FakePlayerDriver.RecordingBindings()
        var playersBuilt = 0
        var framesBeforeScorePlay = 0
        var metronomeFrames = 0

        val synthFactory: (Int) -> SynthDriver = { _ ->
            FakeSynthDriver(createdSynths.size).also { synth ->
                if (createdSynths.isEmpty()) {
                    synth.onWriteFloat = { frames ->
                        if (scoreBindings.playCalls.isEmpty()) {
                            framesBeforeScorePlay += frames
                            // Fail rather than hang if the score player is never started.
                            check(framesBeforeScorePlay < 10 * 48_000) { "the score player never started" }
                        } else {
                            scoreBindings.tickToReturn += 240
                        }
                    }
                } else {
                    synth.onWriteFloat = { frames -> metronomeFrames += frames }
                }
                createdSynths += synth
            }
        }

        AudioExporter(
            resolver = StubSoundfontResolver(),
            context = null,
            synthFactory = synthFactory,
            playerFactory = { _ ->
                if (playersBuilt++ == 0) scorePlayer else PlayerDriver(0L, metronomeBindings)
            },
            encoderFactory = { _, _, _ -> FakeAudioFileEncoder() },
            masterTuningControlChanges = MarkerMasterTuning::invoke,
        ).run(
            outputFd = null,
            smfBytes = ByteArray(16),
            strips = strips,
            snapshot = snapshot,
            startTick = 0L,
            endTick = 960L,
            ticksPerBeat = 480,
            format = AudioFileFormat.Wav(),
            sampleRate = 48000,
            countIn = countIn,
            progress = null,
        )
        return Render(
            synthsBuilt = createdSynths.size,
            framesBeforeScorePlay = framesBeforeScorePlay,
            scorePlayCalls = scoreBindings.playCalls.size,
            metronome = metronomeBindings,
            metronomeFrames = metronomeFrames,
        )
    }

    // ── Tests ────────────────────────────────────────────────────────────────

    @Test
    fun theScoreStartsAfterExactlyThePreRoll() = runTest {
        val render = render(snapshot(), countIn = oneSecondCount)

        // One second at 48 kHz, to the frame: the last block of the pre-roll is cut short rather than rounded up to
        // the export's block size, or the music would come in late by up to a block.
        assertEquals(48_000, render.framesBeforeScorePlay)
        assertEquals("the score player is started once, after the count", 1, render.scorePlayCalls)
    }

    @Test
    fun thePreRollScalesWithTheRate() = runTest {
        val render = render(snapshot(rate = 0.5f), countIn = oneSecondCount)

        // The click transport plays the pre-roll at the export's rate, so at half speed the count lasts twice as long
        // — the same `preRollSeconds / rate` live playback and the Apple export wait out.
        assertEquals(96_000, render.framesBeforeScorePlay)
    }

    @Test
    fun theCountBuildsAClickSynthEvenWithTheMetronomeOff() = runTest {
        val render = render(snapshot(metronomeEnabled = false), countIn = oneSecondCount)

        // Wanting a count-in but no click through the piece is a normal combination; live playback opens the
        // metronome's mix path for the pre-roll alone, and so does the export.
        assertEquals("a click synth is built for the count", 2, render.synthsBuilt)
        assertTrue(
            "the count-in sequence is what the click transport plays",
            render.metronome.loadCalls.firstOrNull()?.contentEquals(countInSmf) == true,
        )
        assertEquals("from the head of that sequence", listOf(0L), render.metronome.seekTicks)
        assertEquals("and it is silent after the count", 48_000, render.metronomeFrames)
    }

    @Test
    fun withTheMetronomeOnTheClicksContinueAfterTheCount() = runTest {
        val render = render(snapshot(metronomeEnabled = true), countIn = oneSecondCount)

        // The count-in sequence carries the body's clicks behind the pre-roll, so the same transport keeps clicking
        // through the music.
        assertTrue(
            "the metronome renders past the count, got ${render.metronomeFrames} frames",
            render.metronomeFrames > 48_000,
        )
    }

    @Test
    fun withoutACountInNothingChanges() = runTest {
        val render = render(snapshot(metronomeEnabled = true), countIn = null)

        assertEquals("the music starts on the first frame", 0, render.framesBeforeScorePlay)
        assertTrue(
            "the plain click sequence is loaded",
            render.metronome.loadCalls.firstOrNull()?.contentEquals(bodyClicks) == true,
        )
        assertEquals("and started from the export's start tick", listOf(0L), render.metronome.seekTicks)
    }
}
