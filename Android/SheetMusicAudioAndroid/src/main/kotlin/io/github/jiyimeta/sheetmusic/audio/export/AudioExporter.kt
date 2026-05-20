package io.github.jiyimeta.sheetmusic.audio.export

import android.content.Context
import android.os.ParcelFileDescriptor
import io.github.jiyimeta.sheetmusic.audio.AudioBackendException
import io.github.jiyimeta.sheetmusic.audio.SoundfontResolver
import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat
import io.github.jiyimeta.sheetmusic.audio.model.StaffParams
import io.github.jiyimeta.sheetmusic.audio.synth.FluidSynthDriver
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
) {
    companion object {
        const val BUFFER_FRAMES = 4096
        private const val PROGRESS_EMIT_INTERVAL_MS = 33L
    }

    suspend fun run(
        outputFd: ParcelFileDescriptor?,
        smfBytes: ByteArray,
        staffParams: List<StaffParams>,
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
        var lastProgressEmitMs = 0L
        try {
            applyStaffProgramsAndMixer(synth, staffParams, snapshot)
            if (player.load(smfBytes) != 0) {
                throw AudioBackendException.EngineSetupFailed("player.load returned non-zero")
            }
            if (snapshot.rate != 1.0f) player.setTempo(snapshot.rate.toDouble())
            player.seekTick(startTick)
            player.play()

            val left = FloatArray(BUFFER_FRAMES)
            val right = FloatArray(BUFFER_FRAMES)
            val totalTicks = (endTick - startTick).coerceAtLeast(0)

            while (player.currentTick < endTick) {
                coroutineContext.ensureActive()
                // BUFFER_FRAMES is an upper bound; the loop terminates on
                // currentTick crossing endTick regardless of frame budget.
                val frames = BUFFER_FRAMES
                synth.writeFloat(frames, left, right)
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
            try { encoder.close() } catch (_: Throwable) {}
        }
    }

    /**
     * Resolves a default soundfont, loads it on [synth], and applies
     * per-staff program / drum-channel / CC7 (volume + mute/solo) state
     * derived from [snapshot]. Mirrors the staff setup logic in
     * [io.github.jiyimeta.sheetmusic.audio.synth.FluidSynthEngine.setupStaves]
     * but tailored for one-shot offline export.
     */
    private fun applyStaffProgramsAndMixer(
        synth: SynthDriver,
        staffParams: List<StaffParams>,
        snapshot: ExportEngineSnapshot,
    ) {
        val uri = resolver.defaultGmSoundfontUri
            ?: staffParams.firstOrNull()?.let {
                resolver.soundfontUriFor(it.bankLSB, it.program, it.isDrums)
            }
        val sfid = uri?.let { synth.loadSoundFont(it, context) } ?: -1
        if (sfid >= 0) {
            for (p in staffParams) {
                if (p.isDrums) synth.setChannelType(p.staffIndex, isDrum = true)
                val effectiveBank = if (p.isDrums) 128 else p.bankLSB
                val mixerProgram = snapshot.mixerChannels
                    .firstOrNull { it.staffIndex == p.staffIndex }?.program ?: p.program
                synth.programSelect(sfid, p.staffIndex, effectiveBank, mixerProgram.coerceIn(0, 127))
            }
            val soloed = snapshot.mixerChannels.any { it.isSoloed }
            for (chan in snapshot.mixerChannels) {
                val audible = if (soloed) chan.isSoloed else !chan.isMuted
                val gain = if (audible) chan.volume else 0f
                synth.cc(chan.staffIndex, 7, (gain * 127).toInt().coerceIn(0, 127))
            }
        }
    }
}
