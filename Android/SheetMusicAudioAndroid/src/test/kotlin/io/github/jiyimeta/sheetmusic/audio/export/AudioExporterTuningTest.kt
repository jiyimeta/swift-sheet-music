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
import io.github.jiyimeta.sheetmusic.audio.synth.SynthDriver
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The offline render reproduces the live engine's A4 calibration and whole-score transpose.
 *
 * The Kotlin mirror of Apple's `PlaybackEngine+Export.buildScoreSynth`, which applies
 * `masterTuningCents + transposeSemitones * 100` to the melodic unit and `masterTuningCents` alone to
 * percussion. Android carried neither field on its export snapshot, so a transposed score exported in
 * its original key: transposed playback is a tuning shift and never a re-render, so the SMF the
 * exporter loads holds the authored pitches and nothing downstream moved them.
 *
 * Every assertion is on the fake synth's recorded call log rather than on a flag the exporter sets, and
 * on the CENTS each channel was retuned by rather than on the RPN bytes that carry them. Turning cents
 * into an RPN is `MasterTuning` in SheetMusicAudioCore, shared with the Apple exporter and pinned by
 * `MasterTuningTests` there; this file's subject is which cents each channel gets, which is the half that
 * was wrong on Android. `MarkerMasterTuning` is what makes the log say that outright.
 *
 * What these tests are blind to: whether FluidSynth honours the RPN, and whether the resulting audio
 * is actually at the requested pitch. Both are device observations.
 */
class AudioExporterTuningTest {

    private class StubSoundfontResolver : SoundfontResolver {
        override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean): Uri? = null
        override val defaultGmSoundfontUri: Uri? = null
    }

    private val strips = listOf(
        InstrumentParams(
            partIndex = 0, ordinal = 0, liveChannel = 0,
            bankLSB = 0, program = 0, isDrums = false, displayName = "Melody",
        ),
        InstrumentParams(
            partIndex = 1, ordinal = 0, liveChannel = 9,
            bankLSB = 0, program = 0, isDrums = true, displayName = "Drums",
        ),
    )

    private val channels = listOf(
        MixerChannel(partIndex = 0, ordinal = 0, liveChannel = 0, displayName = "Melody", program = 0),
        MixerChannel(
            partIndex = 1, ordinal = 0, liveChannel = 9, displayName = "Drums",
            program = 0, isDrums = true,
        ),
    )

    private fun snapshot(masterTuningCents: Double, transposeSemitones: Int) = ExportEngineSnapshot(
        mixerChannels = channels,
        metronomeEnabled = false,
        metronomeVolume = 1.0f,
        metronomeSmfBytes = byteArrayOf(),
        rate = 1.0f,
        metronomeResolution = AndroidMetronomeClickResolver.Resolution.DefaultGm,
        masterTuningCents = masterTuningCents,
        transposeSemitones = transposeSemitones,
    )

    /** Runs one export to completion and returns the synth's call log. */
    private fun renderCalls(snapshot: ExportEngineSnapshot): List<String> {
        val synth = FakeSynthDriver()
        val (player, bindings) = FakePlayerDriver.create()
        synth.onWriteFloat = { bindings.tickToReturn += synth.tickAdvancePerWriteFloat }
        synth.tickAdvancePerWriteFloat = 960
        val exporter = AudioExporter(
            resolver = StubSoundfontResolver(),
            context = null,
            synthFactory = { _: Int -> synth as SynthDriver },
            playerFactory = { _: Long -> player },
            encoderFactory = { _, _, _ -> FakeAudioFileEncoder() },
            masterTuningControlChanges = MarkerMasterTuning::invoke,
        )
        runTest {
            exporter.run(
                outputFd = null,
                smfBytes = ByteArray(16),
                strips = strips,
                snapshot = snapshot,
                startTick = 0,
                endTick = 1920,
                ticksPerBeat = 480,
                format = AudioFileFormat.Wav(),
                sampleRate = 48000,
                progress = null,
            )
        }
        return synth.calls.toList()
    }


    @Test
    fun aTransposedScoreRetunesTheMelodicChannel() {
        val calls = renderCalls(snapshot(masterTuningCents = 0.0, transposeSemitones = 2))
        assertTrue(
            "melodic channel 0 must carry the +2-semitone master tuning, got $calls",
            calls.contains(MarkerMasterTuning.marker(channel = 0, cents = 200.0)),
        )
    }

    @Test
    fun aTransposedScoreLeavesPercussionAtConcertPitch() {
        val calls = renderCalls(snapshot(masterTuningCents = 0.0, transposeSemitones = 2))
        // The drum channel's own cents are the calibration alone — zero here — so it must receive no
        // tuning RPN at all. Asserting "the melodic one moved" cannot see a transpose leaking onto
        // the kit, which would raise every drum by a whole tone.
        assertEquals(
            "no RPN may reach the drum channel, got $calls",
            emptyList<String>(),
            calls.filter { it.startsWith("cc(9,") },
        )
    }

    @Test
    fun calibrationAndTransposeCombineOnMelodicAndCalibrationAloneOnPercussion() {
        val calls = renderCalls(snapshot(masterTuningCents = 100.0, transposeSemitones = 3))
        // Melodic: 100 + 300 = 400 cents. Percussion: the 100 of calibration alone. The two channels must
        // disagree, which a fixture with a zero calibration could not show.
        assertTrue(
            "melodic channel must carry calibration + transpose, got $calls",
            calls.contains(MarkerMasterTuning.marker(channel = 0, cents = 400.0)),
        )
        assertTrue(
            "drum channel must carry the calibration alone, got $calls",
            calls.contains(MarkerMasterTuning.marker(channel = 9, cents = 100.0)),
        )
    }

    @Test
    fun aFractionalCalibrationReachesTheChannelUnrounded() {
        val calls = renderCalls(snapshot(masterTuningCents = -13.7, transposeSemitones = -1))
        // -113.7 cents, not -100: an exporter that combined the two by whole semitones would drop the 13.7
        // and pass every other case in this file. That the fraction then survives INTO the RPN's fine half
        // is `MasterTuningTests`' business, on the Swift side where the split lives.
        assertTrue(
            "the fractional calibration must survive the combination, got $calls",
            calls.contains(MarkerMasterTuning.marker(channel = 0, cents = -113.7)),
        )
    }

    @Test
    fun anUntunedScoreSendsNoTuningAtAll() {
        val calls = renderCalls(snapshot(masterTuningCents = 0.0, transposeSemitones = 0))
        // The negative control: with no calibration and no transpose the render must be byte-for-byte the
        // sequence it produced before tuning existed, so no retune may be asked for at all.
        assertEquals(
            "an untuned export must ask for no retune, got $calls",
            emptyList<String>(),
            calls.filter { it.contains(",${MarkerMasterTuning.CONTROLLER},") },
        )
    }
}
