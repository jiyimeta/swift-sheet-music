package io.github.jiyimeta.sheetmusic.audio.export

import android.net.FakeUri
import android.net.Uri
import io.github.jiyimeta.sheetmusic.audio.SoundfontResolver
import io.github.jiyimeta.sheetmusic.audio.export.fakes.FakeAudioFileEncoder
import io.github.jiyimeta.sheetmusic.audio.fakes.FakePlayerDriver
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

    /**
     * `applyStripProgramsAndMixer` only calls `synth.loadSoundFont` — and
     * therefore only runs its whole program/bank/CC7 block — when the
     * resolved URI is non-null (`uri?.let { synth.loadSoundFont(...) } ?:
     * -1`, pre-existing behavior, unrelated to this task). Every fixture
     * above uses [StubSoundfontResolver], whose null URI means that block
     * has NEVER run in this file. [FakeUri] (declared in `android.net` —
     * see its doc comment for why) gives it a real, non-null reference.
     */
    private class NonNullUriResolver : SoundfontResolver {
        private val fakeUri: Uri = FakeUri()
        override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean): Uri = fakeUri
        override val defaultGmSoundfontUri: Uri = fakeUri
    }

    // ── Fixtures ────────────────────────────────────────────────────────

    private val snapshot = ExportEngineSnapshot(
        mixerChannels = listOf(
            MixerChannel(partIndex = 0, ordinal = 0, liveChannel = 0, displayName = "Staff 1", program = 0),
        ),
        metronomeEnabled = false,
        metronomeVolume = 1.0f,
        metronomeSmfBytes = byteArrayOf(),
        rate = 1.0f,
        metronomeResolution = AndroidMetronomeClickResolver.Resolution.DefaultGm,
    )

    private val strips = listOf(
        InstrumentParams(
            partIndex = 0, ordinal = 0, liveChannel = 0,
            bankLSB = 0, program = 0, isDrums = false, displayName = "Staff 1",
        ),
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

    private fun makeExporter(
        drivers: Drivers,
        encoder: FakeAudioFileEncoder,
        resolver: SoundfontResolver = StubSoundfontResolver(),
    ): AudioExporter =
        AudioExporter(
            resolver = resolver,
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
            strips = strips,
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
            strips = strips,
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
            strips = strips,
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

    // ── applyStripProgramsAndMixer: two-strip join (Finding 3) ──────────
    //
    // The fixtures above are all single-strip at partIndex=0/ordinal=0/
    // liveChannel=0 — the degenerate case where the NEW two-source join
    // (`strips` for bank/drum-flag, `snapshot.mixerChannels` for the live
    // program/volume) produces identical calls to what a naive
    // single-source implementation would. This fixture uses two strips —
    // one melodic on a NON-zero channel with a NON-zero bank, one drum on
    // channel 9 — and gives the mixer snapshot a DIFFERENT (live-override)
    // program than the strip's authored one, so the two sources can only
    // both be right if the join is actually keyed on `liveChannel`.

    private val twoStripSnapshot = ExportEngineSnapshot(
        mixerChannels = listOf(
            // Live state: user has swapped the program away from the
            // strip's authored value (12 → 55).
            MixerChannel(partIndex = 0, ordinal = 0, liveChannel = 5, displayName = "Violin", program = 55),
            MixerChannel(
                partIndex = 1, ordinal = 0, liveChannel = 9, displayName = "Drums",
                program = 8, isDrums = true,
            ),
        ),
        metronomeEnabled = false,
        metronomeVolume = 1.0f,
        metronomeSmfBytes = byteArrayOf(),
        rate = 1.0f,
        metronomeResolution = AndroidMetronomeClickResolver.Resolution.DefaultGm,
    )

    private val twoStrips = listOf(
        // Authored bank=3, program=12 — the program must be OVERRIDDEN by
        // the snapshot's live value (55); the bank must come from HERE,
        // since MixerChannel carries no bank field at all.
        InstrumentParams(
            partIndex = 0, ordinal = 0, liveChannel = 5,
            bankLSB = 3, program = 12, isDrums = false, displayName = "Violin",
        ),
        InstrumentParams(
            partIndex = 1, ordinal = 0, liveChannel = 9,
            bankLSB = 0, program = 0, isDrums = true, displayName = "Drums",
        ),
    )

    @Test
    fun twoStripJoinAppliesEachStripsOwnBankAndTheLiveMixerProgram() = runTest {
        val encoder = FakeAudioFileEncoder()
        val drivers = makeDrivers()

        makeExporter(drivers, encoder, resolver = NonNullUriResolver()).run(
            outputFd = null,
            smfBytes = ByteArray(16),
            strips = twoStrips,
            snapshot = twoStripSnapshot,
            startTick = 0,
            endTick = 0,
            ticksPerBeat = 480,
            format = AudioFileFormat.Wav(),
            sampleRate = 48000,
            progress = null,
        )

        val calls = drivers.synth.calls
        // Melodic strip: channel 5, bank 3 (from `strips`, NOT the
        // mixer — MixerChannel carries no bank), program 55 (the LIVE
        // mixer override, not the strip's authored 12).
        assertTrue(
            "expected programSelect(0,5,3,55) in $calls",
            calls.contains("programSelect(0,5,3,55)"),
        )
        // Drum strip: channel 9 locked into drum type, bank forced to
        // 128 regardless of the strip's own (irrelevant) bankLSB, kit
        // program 8 from the mixer.
        assertTrue(
            "expected setChannelType(9,drum) in $calls",
            calls.contains("setChannelType(9,drum)"),
        )
        assertTrue(
            "expected programSelect(0,9,128,8) in $calls",
            calls.contains("programSelect(0,9,128,8)"),
        )
        // Neither strip's CC7 leaks onto the other's channel.
        assertTrue(calls.any { it.startsWith("cc(5,7,") })
        assertTrue(calls.any { it.startsWith("cc(9,7,") })
    }

    /**
     * `MixerChannel.program` defaults to `null` (pinned by
     * [io.github.jiyimeta.sheetmusic.audio.model.MixerChannelTest
     * .mixerChannelDefaultsProgramToNull]) whenever the host never called
     * `setStaffProgram` — i.e. for every export of a score the user hasn't
     * touched the mixer on. A bare `chan.program ?: 0` would silently
     * export such a strip as GM piano instead of its own authored
     * program; the fallback must reach the STRIP's program instead.
     */
    @Test
    fun nullMixerProgramFallsBackToTheStripsOwnAuthoredProgram() = runTest {
        val encoder = FakeAudioFileEncoder()
        val drivers = makeDrivers()
        val untouchedSnapshot = ExportEngineSnapshot(
            mixerChannels = listOf(
                // program left at its null default — never overridden.
                MixerChannel(partIndex = 0, ordinal = 0, liveChannel = 5, displayName = "Violin"),
            ),
            metronomeEnabled = false,
            metronomeVolume = 1.0f,
            metronomeSmfBytes = byteArrayOf(),
            rate = 1.0f,
            metronomeResolution = AndroidMetronomeClickResolver.Resolution.DefaultGm,
        )
        val untouchedStrips = listOf(
            InstrumentParams(
                partIndex = 0, ordinal = 0, liveChannel = 5,
                bankLSB = 0, program = 40, isDrums = false, displayName = "Violin",
            ),
        )

        makeExporter(drivers, encoder, resolver = NonNullUriResolver()).run(
            outputFd = null,
            smfBytes = ByteArray(16),
            strips = untouchedStrips,
            snapshot = untouchedSnapshot,
            startTick = 0,
            endTick = 0,
            ticksPerBeat = 480,
            format = AudioFileFormat.Wav(),
            sampleRate = 48000,
            progress = null,
        )

        assertTrue(
            "expected the strip's authored program (40), not GM piano (0), in ${drivers.synth.calls}",
            drivers.synth.calls.contains("programSelect(0,5,0,40)"),
        )
    }
}
