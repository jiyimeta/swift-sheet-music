package io.github.jiyimeta.sheetmusic.audio.export

import android.net.Uri
import io.github.jiyimeta.sheetmusic.audio.SoundfontResolver
import io.github.jiyimeta.sheetmusic.audio.export.fakes.FakeAudioFileEncoder
import io.github.jiyimeta.sheetmusic.audio.fakes.FakePlayerDriver
import io.github.jiyimeta.sheetmusic.audio.fakes.MarkerMasterTuning
import io.github.jiyimeta.sheetmusic.audio.fakes.FakeSynthDriver
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
 * [AudioExporter] renders the metronome the same way live playback does: a second synth loaded with the
 * click SoundFont, driven by a second player over the metronome's own SMF. The offline render therefore
 * places clicks on exactly the ticks the user heard, rather than quantized to the export block size.
 */
class AudioExporterMetronomeTest {

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

    private val metronomeSmf = byteArrayOf(1, 2, 3, 4)

    private fun snapshot(metronomeEnabled: Boolean, smf: ByteArray = metronomeSmf) = ExportEngineSnapshot(
        mixerChannels = listOf(
            MixerChannel(partIndex = 0, ordinal = 0, liveChannel = 0, displayName = "Staff 1", program = 0),
        ),
        metronomeEnabled = metronomeEnabled,
        metronomeVolume = 1.0f,
        metronomeSmfBytes = smf,
        rate = 1.0f,
        metronomeResolution = AndroidMetronomeClickResolver.Resolution.DefaultGm,
    )

    /**
     * Runs an export whose score synth advances the score player on every `writeFloat`, and hands the
     * metronome its own player so the two transports' calls can be told apart.
     *
     * @return the synths that were created, and the metronome player's recorded calls.
     */
    private suspend fun runExport(
        snapshot: ExportEngineSnapshot,
    ): Pair<List<FakeSynthDriver>, FakePlayerDriver.RecordingBindings> {
        val createdSynths = mutableListOf<FakeSynthDriver>()
        val (scorePlayer, scoreBindings) = FakePlayerDriver.create()
        val metronomeBindings = FakePlayerDriver.RecordingBindings()
        var playersBuilt = 0

        val synthFactory: (Int) -> SynthDriver = { _ ->
            FakeSynthDriver(createdSynths.size).also { synth ->
                // Score synth (index 0): advance the player tick on every writeFloat so the render loop
                // terminates. The metronome synth is a passive recorder.
                if (createdSynths.isEmpty()) synth.onWriteFloat = { scoreBindings.tickToReturn += 240 }
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
            progress = null,
        )
        return createdSynths to metronomeBindings
    }

    // ── Tests ────────────────────────────────────────────────────────────────

    @Test
    fun exportDrivesTheMetronomeTransportWhenEnabled() = runTest {
        val (synths, metronome) = runExport(snapshot(metronomeEnabled = true))

        assertTrue("a second synth is created for the click SoundFont", synths.size >= 2)
        assertEquals("the metronome SMF is loaded", 1, metronome.loadCalls.size)
        assertTrue(metronome.loadCalls[0].contentEquals(metronomeSmf))
        assertEquals("and its transport is started", 1, metronome.playCalls.size)
    }

    @Test
    fun theMetronomeStartsFromTheExportsStartTick() = runTest {
        val (_, metronome) = runExport(snapshot(metronomeEnabled = true))

        // Both transports are placed at startTick and then advanced by identical frame counts, which is
        // what makes an exported region's clicks line up with its notes.
        assertEquals(listOf(0L), metronome.seekTicks)
    }

    @Test
    fun exportSkipsTheMetronomeWhenDisabled() = runTest {
        val (synths, metronome) = runExport(snapshot(metronomeEnabled = false))

        assertEquals("no click synth is built at all", 1, synths.size)
        assertTrue("and no click transport", metronome.playCalls.isEmpty())
    }

    @Test
    fun exportSkipsTheMetronomeWhenTheScoreHasNoClickSequence() = runTest {
        // An older native bridge (or a score with no beats) yields no metronome SMF; the export must
        // still run, just without clicks.
        val (synths, metronome) = runExport(
            snapshot(metronomeEnabled = true, smf = byteArrayOf()),
        )

        assertEquals(1, synths.size)
        assertTrue(metronome.playCalls.isEmpty())
    }
}
