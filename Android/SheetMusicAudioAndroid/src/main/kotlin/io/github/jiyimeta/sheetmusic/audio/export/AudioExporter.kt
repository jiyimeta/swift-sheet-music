package io.github.jiyimeta.sheetmusic.audio.export

import android.content.Context
import android.os.ParcelFileDescriptor
import io.github.jiyimeta.sheetmusic.audio.AudioBackendException
import io.github.jiyimeta.sheetmusic.audio.SoundfontResolver
import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat
import io.github.jiyimeta.sheetmusic.audio.model.InstrumentParams
import io.github.jiyimeta.sheetmusic.audio.model.MidiControlChange
import io.github.jiyimeta.sheetmusic.audio.synth.FluidSynthDriver
import io.github.jiyimeta.sheetmusic.audio.synth.MetronomeMixer
import io.github.jiyimeta.sheetmusic.audio.synth.MetronomeSf2Loader
import io.github.jiyimeta.sheetmusic.audio.synth.PlayerDriver
import io.github.jiyimeta.sheetmusic.audio.synth.SynthDriver
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ensureActive
import kotlin.coroutines.coroutineContext

/**
 * Orchestrates an offline audio render: builds a dedicated FluidSynth +
 * PlayerDriver, applies the [ExportEngineSnapshot], pumps PCM through the
 * encoder, and tears down on completion / cancellation / failure.
 *
 * Mirrors the structure of Apple's AudioFileExporter actor.
 */
internal class AudioExporter(
    private val resolver: SoundfontResolver,
    private val context: Context?,
    private val synthFactory: (Int) -> SynthDriver = { FluidSynthDriver.create(it) },
    private val playerFactory: (Long) -> PlayerDriver = { PlayerDriver(it) },
    private val encoderFactory: (AudioFileFormat, Int, ParcelFileDescriptor?) -> AudioFileEncoder =
        { fmt, sr, fd -> AudioFileEncoder.create(fmt, sr, fd!!) },
    /**
     * The RPN messages that retune one channel by a cents offset off A4=440.
     *
     * Injected rather than computed here: the split into coarse semitones and fine cents is `MasterTuning` in
     * SheetMusicAudioCore, which the Apple engine reads too — it feeds the same numbers into the AUMIDISynth's
     * global tuning params instead of into an RPN. Kotlin held a hand-port of that arithmetic kept honest by
     * golden assertions on both sides; goldens catch a change made twice and made differently, and say nothing
     * about a change made once.
     */
    private val masterTuningControlChanges: (cents: Double) -> List<MidiControlChange>,
) {
    companion object {
        const val BUFFER_FRAMES = 4096
        private const val PROGRESS_EMIT_INTERVAL_MS = 33L
    }

    suspend fun run(
        outputFd: ParcelFileDescriptor?,
        smfBytes: ByteArray,
        strips: List<InstrumentParams>,
        snapshot: ExportEngineSnapshot,
        startTick: Long,
        endTick: Long,
        ticksPerBeat: Int,
        format: AudioFileFormat,
        sampleRate: Int,
        progress: ((Float) -> Unit)?,
    ) {
        val synth = synthFactory(sampleRate)
        val player = playerFactory(synth.nativeHandle)
        val encoder = encoderFactory(format, sampleRate, outputFd)
        val metronomeMixer =
            if (snapshot.metronomeEnabled && snapshot.metronomeSmfBytes.isNotEmpty()) {
                val ms = synthFactory(sampleRate)
                MetronomeSf2Loader.load(ms, snapshot.metronomeResolution, resolver, context)
                ms.setGain(snapshot.metronomeVolume)
                val mixer = MetronomeMixer(ms) { smf ->
                    val mp = playerFactory(ms.nativeHandle)
                    if (mp.load(smf) == 0) mp else { mp.close(); null }
                }
                mixer.loadSequence(snapshot.metronomeSmfBytes)
                mixer.also { it.isEnabled = true }
            } else {
                null
            }
        var lastProgressEmitMs = 0L
        try {
            applyStripProgramsAndMixer(synth, strips, snapshot)
            applyMasterTuning(synth, snapshot)
            if (player.load(smfBytes) != 0) {
                throw AudioBackendException.EngineSetupFailed("player.load returned non-zero")
            }
            if (snapshot.rate != 1.0f) {
                player.setTempo(snapshot.rate.toDouble())
                metronomeMixer?.setTempo(snapshot.rate.toDouble())
            }
            player.seekTick(startTick)
            player.play()
            // Both transports start from the same tick and are then advanced by the same frame counts
            // below, so the offline render places clicks exactly where live playback does.
            metronomeMixer?.start(startTick)

            val left = FloatArray(BUFFER_FRAMES)
            val right = FloatArray(BUFFER_FRAMES)
            val totalTicks = (endTick - startTick).coerceAtLeast(0)

            while (player.currentTick < endTick) {
                coroutineContext.ensureActive()
                // BUFFER_FRAMES is an upper bound; the loop terminates on
                // currentTick crossing endTick regardless of frame budget.
                val frames = BUFFER_FRAMES
                synth.writeFloat(frames, left, right)
                metronomeMixer?.let { mm ->
                    val mLeft = FloatArray(frames)
                    val mRight = FloatArray(frames)
                    mm.synth.writeFloat(frames, mLeft, mRight)
                    for (i in 0 until frames) {
                        left[i] += mLeft[i]
                        right[i] += mRight[i]
                    }
                }
                encoder.appendPcmFloat(left, right, frames)
                val nowMs = System.currentTimeMillis()
                if (progress != null && totalTicks > 0 &&
                    nowMs - lastProgressEmitMs >= PROGRESS_EMIT_INTERVAL_MS
                ) {
                    val done = (player.currentTick - startTick).toDouble() / totalTicks.toDouble()
                    progress(done.coerceIn(0.0, 1.0).toFloat())
                    lastProgressEmitMs = nowMs
                }
            }
            encoder.finish()
            progress?.invoke(1.0f)
        } catch (c: CancellationException) {
            throw AudioBackendException.Cancelled().apply { initCause(c) }
        } finally {
            // Teardown: swallow close failures so a primary exception
            // (e.g. EngineSetupFailed) propagates without being masked.
            try { player.close() } catch (_: Throwable) {}
            try { synth.close() } catch (_: Throwable) {}
            try { metronomeMixer?.close() } catch (_: Throwable) {}
            try { encoder.close() } catch (_: Throwable) {}
        }
    }

    /**
     * Resolves a default soundfont, loads it on [synth], and applies
     * per-strip program / drum-channel / CC7 (volume + mute/solo) state.
     * Mirrors the channel setup logic in
     * [io.github.jiyimeta.sheetmusic.audio.synth.FluidSynthEngine.setupStaves]
     * but tailored for one-shot offline export.
     *
     * Two sources, joined on [InstrumentParams.liveChannel] /
     * [io.github.jiyimeta.sheetmusic.audio.model.MixerChannel.liveChannel] —
     * the channel the rendered SMF ([AudioMidiBridge.renderMidi]) actually
     * addresses once a score has a drum part, a grand staff, or a mid-score
     * instrument change (no longer the same as a staff index):
     * - [strips] (score-authored): bank + drum flag, and the fallback
     *   program/soundfont-URI resolution.
     * - [snapshot]'s `mixerChannels` (live/user state): the CURRENT
     *   program (post any `setStaffProgram` override) + volume/mute/solo.
     */
    private fun applyStripProgramsAndMixer(
        synth: SynthDriver,
        strips: List<InstrumentParams>,
        snapshot: ExportEngineSnapshot,
    ) {
        val uri = resolver.defaultGmSoundfontUri
            ?: strips.firstOrNull()?.let {
                resolver.soundfontUriFor(it.bankLSB.toInt(), it.program.toInt(), it.isDrums)
            }
        val sfid = uri?.let { synth.loadSoundFont(it, context) } ?: -1
        if (sfid >= 0) {
            val bankByChannel = strips.associate {
                it.liveChannel to (if (it.isDrums) 128 else it.bankLSB.toInt())
            }
            // MixerChannel.program is null whenever the host never overrode
            // the score's authored program (it defaults to null — pinned by
            // MixerChannelTest.mixerChannelDefaultsProgramToNull). Falling
            // back to a bare `0` there would export every un-touched strip
            // as GM piano instead of its own authored program; fall back to
            // the STRIP's own program instead, keyed the same way as bank.
            val programByChannel = strips.associate { it.liveChannel to it.program.toInt() }
            for (chan in snapshot.mixerChannels) {
                if (chan.isDrums) synth.setChannelType(chan.liveChannel, isDrum = true)
                val effectiveBank = bankByChannel[chan.liveChannel]
                    ?: if (chan.isDrums) 128 else 0
                val program = chan.program ?: programByChannel[chan.liveChannel] ?: 0
                synth.programSelect(sfid, chan.liveChannel, effectiveBank, program.coerceIn(0, 127))
            }
            val soloed = snapshot.mixerChannels.any { it.isSoloed }
            for (chan in snapshot.mixerChannels) {
                val audible = if (soloed) chan.isSoloed else !chan.isMuted
                val gain = if (audible) chan.volume else 0f
                synth.cc(chan.liveChannel, 7, (gain * 127).toInt().coerceIn(0, 127))
            }
        }
    }

    /**
     * Reproduces the live engine's pitch state on the offline synth via MIDI Master Tuning RPN.
     *
     * Melodic channels take calibration + transpose (100 cents per semitone); percussion takes the
     * calibration alone, so a transposed score's drums stay where they were written. That is the same
     * split Apple's exporter makes in `PlaybackEngine+Export.buildScoreSynth`.
     *
     * This is not a nicety: transposed playback is a tuning shift and never a re-render, so the SMF
     * this exporter loads carries the AUTHORED pitches. With no tuning applied, a score transposed on
     * screen exports in its original key — silently, on every device.
     *
     * Zero is skipped rather than sent as a no-op RPN, mirroring the live engine's own
     * `if (effectiveTuningCents != 0.0)` guard at prepare.
     */
    private fun applyMasterTuning(synth: SynthDriver, snapshot: ExportEngineSnapshot) {
        val melodicCents = snapshot.masterTuningCents + snapshot.transposeSemitones * 100.0
        for (chan in snapshot.mixerChannels) {
            val cents = if (chan.isDrums) snapshot.masterTuningCents else melodicCents
            if (cents == 0.0) continue
            for (cc in masterTuningControlChanges(cents)) {
                synth.cc(chan.liveChannel, cc.controller, cc.value)
            }
        }
    }
}
