package io.github.jiyimeta.sheetmusic.audio.export

import android.net.Uri
import io.github.jiyimeta.sheetmusic.audio.SoundfontResolver
import io.github.jiyimeta.sheetmusic.audio.export.fakes.FakeAudioFileEncoder
import io.github.jiyimeta.sheetmusic.audio.fakes.FakePlayerDriver
import io.github.jiyimeta.sheetmusic.audio.fakes.FakeSynthDriver
import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat
import io.github.jiyimeta.sheetmusic.audio.model.MetronomeBeat
import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel
import io.github.jiyimeta.sheetmusic.audio.model.StaffParams
import io.github.jiyimeta.sheetmusic.audio.synth.AndroidMetronomeClickResolver
import io.github.jiyimeta.sheetmusic.audio.synth.SynthDriver
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * TDD tests verifying that [AudioExporter] mixes a metronome synth into the
 * offline render when [ExportEngineSnapshot.metronomeEnabled] is true, and
 * skips it when false.
 *
 * Uses the same fakes as [AudioExporterTest]: [FakeSynthDriver] (records all
 * [SynthDriver] calls including noteOn), [FakePlayerDriver.create] (real
 * [io.github.jiyimeta.sheetmusic.audio.synth.PlayerDriver] backed by
 * [FakePlayerDriver.RecordingBindings]), and [FakeAudioFileEncoder].
 */
class AudioExporterMetronomeTest {

    // ── Stubs ────────────────────────────────────────────────────────────────

    private class StubSoundfontResolver : SoundfontResolver {
        override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean): Uri? = null
        override val defaultGmSoundfontUri: Uri? = null
    }

    // ── Fixtures ─────────────────────────────────────────────────────────────

    private val staffParams = listOf(
        StaffParams(staffIndex = 0, bankLSB = 0, program = 0, isDrums = false, partAddressHash = 0L),
    )

    // One downbeat at tick 0 — fires on the very first updateCurrentTick call.
    private val singleDownbeat = listOf(MetronomeBeat(tick = 0L, isDownbeat = true))

    // ── Tests ────────────────────────────────────────────────────────────────

    @Test
    fun exportFiresMetronomeNotesWhenEnabled() = runTest {
        val createdSynths = mutableListOf<FakeSynthDriver>()

        // synthFactory: create a fresh FakeSynthDriver each time (index 0 = score, 1 = metronome).
        // The render loop needs the score synth's writeFloat to advance the player tick
        // (same wiring as AudioExporterTest.makeDrivers). The metronome synth is a
        // passive recorder — its writeFloat is a no-op and that is fine.
        val (player, bindings) = FakePlayerDriver.create()

        val synthFactory: (Int) -> SynthDriver = { _ ->
            FakeSynthDriver(createdSynths.size).also { synth ->
                if (createdSynths.isEmpty()) {
                    // Score synth (index 0): advance player tick on every writeFloat.
                    synth.onWriteFloat = { bindings.tickToReturn += 240 }
                }
                // sfidToReturn = 0 (default) → loadSoundFont succeeds (sfid >= 0).
                createdSynths += synth
            }
        }

        val encoder = FakeAudioFileEncoder()
        val snapshot = ExportEngineSnapshot(
            mixerChannels = listOf(MixerChannel(staffIndex = 0, displayName = "Staff 1", program = 0)),
            metronomeEnabled = true,
            metronomeVolume = 1.0f,
            metronomeBeats = singleDownbeat,
            rate = 1.0f,
            metronomeResolution = AndroidMetronomeClickResolver.Resolution.DefaultGm,
        )

        AudioExporter(
            resolver = StubSoundfontResolver(),
            context = null,
            synthFactory = synthFactory,
            playerFactory = { _ -> player },
            encoderFactory = { _, _, _ -> encoder },
        ).run(
            outputFd = null,
            smfBytes = ByteArray(16),
            staffParams = staffParams,
            snapshot = snapshot,
            startTick = 0L,
            endTick = 960L,
            ticksPerBeat = 480,
            format = AudioFileFormat.Wav(),
            sampleRate = 48000,
            progress = null,
        )

        assertTrue(
            "exportFiresMetronomeNotesWhenEnabled: two synths should be created (score + metronome)",
            createdSynths.size >= 2,
        )

        val metronomeSynth = createdSynths[1]
        val channel9NoteOns = metronomeSynth.calls.filter { it.startsWith("noteOn(9,") }
        assertTrue(
            "exportFiresMetronomeNotesWhenEnabled: metronome synth should receive at least one noteOn on channel 9; calls=${metronomeSynth.calls}",
            channel9NoteOns.isNotEmpty(),
        )
    }

    @Test
    fun exportSkipsMetronomeWhenDisabled() = runTest {
        val createdSynths = mutableListOf<FakeSynthDriver>()

        val (player, bindings) = FakePlayerDriver.create()

        val synthFactory: (Int) -> SynthDriver = { _ ->
            FakeSynthDriver(createdSynths.size).also { synth ->
                if (createdSynths.isEmpty()) {
                    synth.onWriteFloat = { bindings.tickToReturn += 240 }
                }
                createdSynths += synth
            }
        }

        val encoder = FakeAudioFileEncoder()
        val snapshot = ExportEngineSnapshot(
            mixerChannels = listOf(MixerChannel(staffIndex = 0, displayName = "Staff 1", program = 0)),
            metronomeEnabled = false,
            metronomeVolume = 1.0f,
            metronomeBeats = singleDownbeat,
            rate = 1.0f,
            metronomeResolution = AndroidMetronomeClickResolver.Resolution.DefaultGm,
        )

        AudioExporter(
            resolver = StubSoundfontResolver(),
            context = null,
            synthFactory = synthFactory,
            playerFactory = { _ -> player },
            encoderFactory = { _, _, _ -> encoder },
        ).run(
            outputFd = null,
            smfBytes = ByteArray(16),
            staffParams = staffParams,
            snapshot = snapshot,
            startTick = 0L,
            endTick = 960L,
            ticksPerBeat = 480,
            format = AudioFileFormat.Wav(),
            sampleRate = 48000,
            progress = null,
        )

        // When disabled, no second synth should be created at all.
        val scoreSynth = createdSynths[0]
        val metronomeChannel9NoteOns = if (createdSynths.size >= 2) {
            createdSynths[1].calls.filter { it.startsWith("noteOn(9,") }
        } else {
            emptyList()
        }

        val noMetronomeSynth = createdSynths.size == 1
        val noChannel9NoteOns = metronomeChannel9NoteOns.isEmpty()

        assertTrue(
            "exportSkipsMetronomeWhenDisabled: either no second synth was created OR it received no noteOn on channel 9; createdSynths.size=${createdSynths.size}, channel9NoteOns=$metronomeChannel9NoteOns",
            noMetronomeSynth || noChannel9NoteOns,
        )

        // The score synth should never receive channel 9 noteOn from the metronome.
        assertFalse(
            "exportSkipsMetronomeWhenDisabled: score synth should not receive metronome noteOn(9,...)",
            scoreSynth.calls.any { it.startsWith("noteOn(9,") },
        )
    }
}
