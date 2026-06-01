package io.github.jiyimeta.sheetmusic.audio.export

import android.net.Uri
import io.github.jiyimeta.sheetmusic.audio.SoundfontResolver
import io.github.jiyimeta.sheetmusic.audio.export.fakes.FakeAudioFileEncoder
import io.github.jiyimeta.sheetmusic.audio.fakes.FakePlayerDriver
import io.github.jiyimeta.sheetmusic.audio.fakes.FakeSynthDriver
import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat
import io.github.jiyimeta.sheetmusic.audio.model.MixerChannel
import io.github.jiyimeta.sheetmusic.audio.model.StaffParams
import io.github.jiyimeta.sheetmusic.audio.synth.AndroidMetronomeClickResolver
import io.github.jiyimeta.sheetmusic.audio.synth.PlayerDriver
import io.github.jiyimeta.sheetmusic.audio.synth.SynthDriver
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [AudioExporter]'s offline render loop. Uses [FakeSynthDriver]
 * (extended with the [FakeSynthDriver.onWriteFloat] / [FakeSynthDriver.tickAdvancePerWriteFloat]
 * render-loop affordances) and [FakePlayerDriver.create] (real [PlayerDriver]
 * with [FakePlayerDriver.RecordingBindings]) to drive the loop deterministically.
 */
class AudioExporterTest {

    // ── Test stubs ──────────────────────────────────────────────────────

    private class StubSoundfontResolver : SoundfontResolver {
        override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean): Uri? = null
        override val defaultGmSoundfontUri: Uri? = null
    }

    // ── Fixtures ────────────────────────────────────────────────────────

    private val snapshot = ExportEngineSnapshot(
        mixerChannels = listOf(
            MixerChannel(staffIndex = 0, displayName = "Staff 1", program = 0),
        ),
        metronomeEnabled = false,
        metronomeVolume = 1.0f,
        metronomeBeats = emptyList(),
        rate = 1.0f,
        metronomeResolution = AndroidMetronomeClickResolver.Resolution.DefaultGm,
    )

    private val staffParams = listOf(
        StaffParams(staffIndex = 0, bankLSB = 0, program = 0, isDrums = false, partAddressHash = 0L),
    )

    /**
     * Holds a synth + player + bindings triple wired such that every
     * [FakeSynthDriver.writeFloat] advances the player's reported tick by
     * [FakeSynthDriver.tickAdvancePerWriteFloat]. This is the render-loop
     * test affordance described on [FakeSynthDriver.onWriteFloat].
     */
    private class Drivers(
        val synth: FakeSynthDriver,
        val player: PlayerDriver,
        val bindings: FakePlayerDriver.RecordingBindings,
    )

    private fun makeDrivers(): Drivers {
        val synth = FakeSynthDriver()
        val (player, bindings) = FakePlayerDriver.create()
        synth.onWriteFloat = { bindings.tickToReturn += synth.tickAdvancePerWriteFloat }
        return Drivers(synth, player, bindings)
    }

    private fun makeExporter(drivers: Drivers, encoder: FakeAudioFileEncoder): AudioExporter =
        AudioExporter(
            resolver = StubSoundfontResolver(),
            context = null,
            synthFactory = { _: Int -> drivers.synth as SynthDriver },
            playerFactory = { _: Long -> drivers.player },
            encoderFactory = { _, _, _ -> encoder },
        )

    // ── Tests ───────────────────────────────────────────────────────────

    @Test
    fun renderLoopTerminatesAtEndTick() = runTest {
        val encoder = FakeAudioFileEncoder()
        val drivers = makeDrivers()
        drivers.synth.tickAdvancePerWriteFloat = 240

        makeExporter(drivers, encoder).run(
            outputFd = null,
            smfBytes = ByteArray(16),
            staffParams = staffParams,
            snapshot = snapshot,
            startTick = 0,
            endTick = 1920,
            ticksPerBeat = 480,
            format = AudioFileFormat.Wav(),
            sampleRate = 48000,
            progress = null,
        )

        assertTrue("encoder.finish() should have been called", encoder.finished)
        assertTrue("encoder should have received frames", encoder.totalFramesWritten > 0)
        // The exporter closes the player in `finally`, which zeroes its handle
        // and makes `currentTick` return 0. Read the underlying recording state
        // (the last tick the bindings reported during the loop) instead.
        assertTrue(
            "player should have advanced past endTick (tickToReturn=${drivers.bindings.tickToReturn})",
            drivers.bindings.tickToReturn >= 1920,
        )
        assertTrue("player should have been closed in finally", drivers.bindings.closeCalled)
    }

    @Test
    fun emptyRangeWritesHeaderOnly() = runTest {
        val encoder = FakeAudioFileEncoder()
        val drivers = makeDrivers()

        makeExporter(drivers, encoder).run(
            outputFd = null,
            smfBytes = ByteArray(16),
            staffParams = staffParams,
            snapshot = snapshot,
            startTick = 0,
            endTick = 0,
            ticksPerBeat = 480,
            format = AudioFileFormat.Wav(),
            sampleRate = 48000,
            progress = null,
        )

        assertTrue(encoder.finished)
        assertEquals(0, encoder.totalFramesWritten)
    }

    @Test
    fun progressIsEmittedAndReachesOne() = runTest {
        val encoder = FakeAudioFileEncoder()
        val drivers = makeDrivers()
        drivers.synth.tickAdvancePerWriteFloat = 240
        val progressValues = mutableListOf<Float>()

        makeExporter(drivers, encoder).run(
            outputFd = null,
            smfBytes = ByteArray(16),
            staffParams = staffParams,
            snapshot = snapshot,
            startTick = 0,
            endTick = 4800,
            ticksPerBeat = 480,
            format = AudioFileFormat.Wav(),
            sampleRate = 48000,
            progress = { progressValues.add(it) },
        )

        assertTrue("progress should be emitted at least once", progressValues.isNotEmpty())
        assertEquals(1.0f, progressValues.last(), 0.001f)
    }
}
