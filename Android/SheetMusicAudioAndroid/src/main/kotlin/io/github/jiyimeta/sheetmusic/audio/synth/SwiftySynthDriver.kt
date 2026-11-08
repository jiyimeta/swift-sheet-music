package io.github.jiyimeta.sheetmusic.audio.synth

import android.content.Context
import android.content.res.AssetFileDescriptor
import android.net.Uri
import io.github.jiyimeta.sheetmusic.audio.AudioBackendException
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackAlignment
import io.github.jiyimeta.sheetmusic.audio.model.RecordingTrack
import java.io.File
import java.io.OutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * Production [SynthDriver] — one SwiftySynth synthesizer in Swift (`HostedSynth`), the same synth the Apple apps play
 * through, built with the same settings.
 *
 * Use [create] to construct; the constructor is private to guarantee the handle is valid.
 *
 * **Every native call is taken under a lock, and a closed driver is inert rather than fatal.** The handle is the
 * address of a retained Swift object; once [close] releases it, any call still passing it would reach freed memory.
 * The locks are what make "closed" mean anything: teardown runs from a `prepare` coroutine while
 * `AndroidPlaybackEngine.stop` reaches `allNotesOff` from the main thread, so a check-then-call would still be closed
 * in the window between the two. (The same discipline `FluidSynthDriver` kept for FluidSynth's pointer, 2.0.1.)
 *
 * **Two locks, so nothing a control call does holds up the render.** The render ([writeFloat], [renderMix]) takes
 * [renderLock] on the audio writer thread every block; every other call takes [controlLock] — among them a track list
 * that maps its files and makes its stretchers, a SoundFont load, a clock read and a prefetch. Only [close] takes both,
 * control first, so it waits out a call of either kind in flight. Render and control meet in the Swift synth alone,
 * whose own lock (`HostedSynth`'s) a control call holds only to swap in what it built outside it, as the Apple
 * backend's do. [controlLock] also keeps two threads from interleaving what they stage (`RecordingBridge.swift`).
 */
internal class SwiftySynthDriver internal constructor(
    private val handle: Long,
    private val native: SynthNativeCalls,
) : SynthDriver {

    private val renderLock = Any()
    private val controlLock = Any()

    /** Written under both locks, so either one reads it settled. */
    private var closed = false

    /** Runs [body] with the live handle under [controlLock], or answers [fallback] once the driver is closed. */
    private inline fun <T> withHandle(fallback: T, body: (Long) -> T): T = synchronized(controlLock) {
        if (closed) fallback else body(handle)
    }

    /** [withHandle] for a render, under [renderLock]. */
    private inline fun <T> rendering(fallback: T, body: (Long) -> T): T = synchronized(renderLock) {
        if (closed) fallback else body(handle)
    }

    companion object {
        /**
         * A synth rendering at [sampleRate], voiced for [voicing] — [SwiftySynthNative.VOICING_SCORE] or
         * [SwiftySynthNative.VOICING_METRONOME] — silent until [loadSoundFont].
         */
        fun create(sampleRate: Int, voicing: Int = SwiftySynthNative.VOICING_SCORE): SwiftySynthDriver {
            val handle = SwiftySynthNative.synthCreate(sampleRate, voicing)
            if (handle == 0L) {
                throw AudioBackendException.SynthInit("no synthesizer at $sampleRate Hz")
            }
            // The score synth is the one recordings are mixed onto; read away from 100 % through Signalsmith Stretch,
            // as the Apple backend reads them.
            if (voicing == SwiftySynthNative.VOICING_SCORE) SwiftySynthNative.enableRecordingStretch(handle)
            return SwiftySynthDriver(handle, SwiftySynthNative)
        }
    }

    /**
     * Loads the SoundFont at [uri]: read in place from its file, memory-mapped, when it is a `file:` URI; copied once
     * into the app's cache first otherwise (a `content:` URI from a document picker has no path to map). Returns 0, the
     * one SoundFont a SwiftySynth synthesizer holds, or -1 on failure.
     */
    override fun loadSoundFont(uri: Uri?, context: Context?): Int {
        if (uri == null) return -1
        val path = soundFontFilePath(uri.scheme, uri.path)
            ?: context?.let { materializeUriToCache(uri, it) }
            ?: return -1
        return withHandle(-1) { native.synthLoadSoundFont(it, path) }
    }

    /**
     * [sfid] is ignored — a SwiftySynth synthesizer holds one SoundFont. A drum kit is bank 128 and up; SwiftySynth
     * sounds one on the percussion channel (9), which is where the playback renderer puts every drum part.
     */
    override fun programSelect(sfid: Int, channel: Int, bank: Int, program: Int) {
        withHandle(Unit) { native.synthProgramSelect(it, channel, bank, program) }
    }

    override fun setGain(value: Float) = withHandle(Unit) { native.synthSetGain(it, value) }

    override fun cc(channel: Int, controller: Int, value: Int) {
        withHandle(Unit) { native.synthControlChange(it, channel, controller, value) }
    }

    override fun getCC(channel: Int, controller: Int): Int =
        withHandle(-1) { native.synthControllerValue(it, channel, controller) }

    /**
     * A no-op: SwiftySynth's percussion channel is channel 9 and only channel 9, and the playback renderer puts every
     * drum part there (`LiveChannelPlan`). A drum bank selected anywhere else plays its melodic fallback.
     */
    override fun setChannelType(channel: Int, isDrum: Boolean) {}

    override fun noteOn(channel: Int, pitch: Int, velocity: Int) {
        withHandle(Unit) { native.synthNoteOn(it, channel, pitch, velocity) }
    }

    override fun noteOff(channel: Int, pitch: Int) {
        withHandle(Unit) { native.synthNoteOff(it, channel, pitch) }
    }

    /** `HostedSynth.pitchBend`: the bend sensitivity, then the wheel — the messages the Apple backend sends. */
    override fun pitchBend(channel: Int, value: Int) {
        withHandle(Unit) { native.synthPitchBend(it, channel, value) }
    }

    override fun allNotesOff(channel: Int) {
        withHandle(Unit) { native.synthAllNotesOff(it, channel) }
    }

    /**
     * Attaches [smf] to this synth under the driver's lock. The handle never leaves the driver: a player built for a
     * synth that a concurrent teardown has already closed gets 0 and stays inert, instead of reaching native code with
     * a released handle (a prepare on its IO thread against a play on the main thread did exactly that).
     */
    override fun attachSequence(smf: ByteArray): Long = withHandle(0L) { native.sequenceCreate(it, smf) }

    /**
     * Renders into [left] / [right] through the attached sequence while it plays, else the synth alone; leaves them
     * untouched and reports 0 frames once closed. One JNI crossing, no allocation.
     */
    override fun writeFloat(frameCount: Int, left: FloatArray, right: FloatArray): Int =
        rendering(0) { native.nativeRender(it, frameCount, left, right) }

    override fun setRecordingTracks(
        tracks: List<RecordingTrack>,
        soloing: Boolean,
        readerTransposeSemitones: Int,
    ): Boolean = withHandle(false) { h ->
        native.recordingsClear(h)
        for (t in tracks) {
            native.recordingsStage(
                h, t.id, t.pcmPath, t.offsetSeconds, t.transposeSemitones, t.volume.toDouble(), t.isMuted, t.isSoloed,
            )
        }
        native.recordingsCommit(h, soloing, readerTransposeSemitones) == 0
    }

    override fun setAlignment(alignment: PlaybackAlignment): Boolean = withHandle(false) { h ->
        native.alignmentClear(h)
        for (s in alignment.warpSpans) native.alignmentAddSpan(h, s.start, s.end, s.duration)
        for (s in alignment.segments) native.alignmentAddSegment(h, "", s.sourceStart, s.sourceEnd, s.outputStart)
        for ((id, segments) in alignment.trackSegments) {
            // An empty id stands for the shared table on the wire; a track's is never empty.
            if (id.isEmpty()) continue
            for (s in segments) native.alignmentAddSegment(h, id, s.sourceStart, s.sourceEnd, s.outputStart)
        }
        native.alignmentCommit(h) == 0
    }

    /**
     * One crossing for both synths, this driver's [renderLock] and then the metronome's held across it — in this order
     * only, and nothing else holds two drivers' locks — so neither is closed under the render. False when the native
     * render left the arrays untouched (an unknown handle, an array too short), so the caller renders another way
     * rather than sending the last block again.
     */
    override fun renderMix(
        metronome: SynthDriver?,
        metronomeAudible: Boolean,
        frameCount: Int,
        left: FloatArray,
        right: FloatArray,
        metronomeLeft: FloatArray,
        metronomeRight: FloatArray,
    ): Boolean {
        val click = metronome as? SwiftySynthDriver
        if (metronome != null && click == null) return false
        return rendering(false) { h ->
            val rendered = if (click == null || click === this) {
                native.nativeRenderMix(h, 0L, false, frameCount, left, right, metronomeLeft, metronomeRight)
            } else {
                synchronized(click.renderLock) {
                    val clickHandle = if (click.closed) 0L else click.handle
                    native.nativeRenderMix(
                        h, clickHandle, metronomeAudible && clickHandle != 0L, frameCount, left, right,
                        metronomeLeft, metronomeRight,
                    )
                }
            }
            rendered == frameCount
        }
    }

    override fun currentOutputSeconds(): Double = withHandle(Double.NaN) { native.currentOutputSeconds(it) }

    override fun outputSecondsAtTick(tick: Long): Double =
        withHandle(Double.NaN) { native.outputSecondsAtTick(it, tick) }

    override fun tickAtOutputSeconds(seconds: Double): Long =
        withHandle(-1L) { native.tickAtOutputSeconds(it, seconds) }

    override fun setTransportScore(scoreHandle: Long) =
        withHandle(Unit) { native.setTransportScore(it, scoreHandle) }

    override fun notatedSecondsAtOutput(seconds: Double): Double =
        withHandle(Double.NaN) { native.notatedSecondsAtOutput(it, seconds) }

    override fun outputSecondsAtNotated(seconds: Double): Double =
        withHandle(Double.NaN) { native.outputSecondsAtNotated(it, seconds) }

    override fun countIn(seconds: Double): CountInTiming? = withHandle(null) { h ->
        val speed = native.countInSpeed(h, seconds)
        CountInTiming(durationSeconds = native.countInDuration(h, seconds), speed = speed.takeIf { it > 0.0 })
    }

    override fun prefetchRecordings(loopStartTick: Long) =
        withHandle(Unit) { native.recordingsPrefetch(it, loopStartTick) }

    override fun close() = synchronized(controlLock) {
        synchronized(renderLock) {
            if (closed) return@synchronized
            // Mark first, so nothing that later reads the flag can observe a handle that has already been released.
            closed = true
            native.synthRelease(handle)
        }
    }

    private fun materializeUriToCache(uri: Uri, context: Context): String? {
        // Content URI → app cacheDir/sf2-cache/<hash>.sf2
        return try {
            val cacheDir = java.io.File(context.cacheDir, "sf2-cache")
            cacheDir.mkdirs()
            val target = java.io.File(cacheDir, "sf-${uri.hashCode()}.sf2")
            // The cache key is the URI, but the bytes behind a URI can change — a host restages its SoundFont and the
            // URI stays identical. Compare lengths so a swap is actually noticed; see `soundFontCacheIsStale`.
            val sourceLength = try {
                context.contentResolver.openAssetFileDescriptor(uri, "r").use {
                    it?.length ?: AssetFileDescriptor.UNKNOWN_LENGTH
                }
            } catch (_: Exception) {
                AssetFileDescriptor.UNKNOWN_LENGTH
            }
            if (soundFontCacheIsStale(target.exists(), target.length(), sourceLength)) {
                val inStream = context.contentResolver.openInputStream(uri) ?: return null
                inStream.use { input -> replaceFileAtomically(target) { out -> input.copyTo(out) } }
            }
            target.absolutePath
        } catch (e: Exception) {
            null
        }
    }
}

/**
 * The file a SoundFont URI names directly — its path for a `file:` URI — or null when it has to be read through a
 * content resolver. Opening the file in place lets SwiftySynth map it, so the high-quality General MIDI font (~205 MB)
 * is neither copied into the cache nor counted in the app's memory, and the score and metronome synths share one
 * mapping (`SoundFontCache`).
 */
internal fun soundFontFilePath(scheme: String?, path: String?): String? =
    if (scheme == "file" && !path.isNullOrEmpty()) path else null

/**
 * Replaces [target] with what [write] writes, as a new file renamed over it: written next to it under a temporary name,
 * then moved into place in one rename. The old file is never truncated or rewritten — a synth, an export or a prefetch
 * may still have it memory-mapped, and a page of a mapping that a truncation removed is a SIGBUS on the render thread's
 * next read. Its mappings keep the old bytes until they are released; the next load maps the new file. On failure the
 * old copy stays and the temporary file is deleted.
 */
internal fun replaceFileAtomically(target: File, write: (OutputStream) -> Unit) {
    val temporary = File.createTempFile("${target.name}.", ".partial", target.parentFile)
    try {
        temporary.outputStream().use(write)
        Files.move(
            temporary.toPath(), target.toPath(),
            StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING,
        )
    } finally {
        temporary.delete()
    }
}

/**
 * Whether the cached SoundFont copy must be re-materialized from its source.
 *
 * `materializeUriToCache` keys its cache on the URI alone. A URI does not change when the host swaps the file behind
 * it, so refreshing only when the copy was missing or empty served stale bytes forever, surviving every reinstall.
 * Comparing lengths is what makes a swap visible.
 *
 * [sourceLength] is [AssetFileDescriptor.UNKNOWN_LENGTH] when the provider does not report one. In that case the
 * existing copy is kept: re-copying on every launch would make each start pay a multi-hundred-megabyte copy, and the
 * length check still covers every provider that does report one.
 */
internal fun soundFontCacheIsStale(
    targetExists: Boolean,
    targetLength: Long,
    sourceLength: Long,
): Boolean {
    if (!targetExists || targetLength == 0L) return true
    if (sourceLength == AssetFileDescriptor.UNKNOWN_LENGTH) return false
    return targetLength != sourceLength
}
