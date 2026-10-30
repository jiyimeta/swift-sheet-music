package io.github.jiyimeta.sheetmusic.audio.synth

import android.content.Context
import android.content.res.AssetFileDescriptor
import android.net.Uri
import io.github.jiyimeta.sheetmusic.audio.AudioBackendException
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
 * **Every native call is taken under [lock], and a closed driver is inert rather than fatal.** The handle is the
 * address of a retained Swift object; once [close] releases it, any call still passing it would reach freed memory.
 * The lock is what makes "closed" mean anything: teardown runs from a `prepare` coroutine while
 * `AndroidPlaybackEngine.stop` reaches `allNotesOff` from the main thread, so a check-then-call would still be closed
 * in the window between the two. It also serializes [close] against a call already in flight — the render included,
 * which is why that lock is taken on the audio writer thread every block; it is uncontended in the steady state.
 * (The same discipline `FluidSynthDriver` kept for FluidSynth's pointer, 2.0.1.)
 */
internal class SwiftySynthDriver internal constructor(
    private val handle: Long,
    private val native: SynthNativeCalls,
) : SynthDriver {

    private val lock = Any()
    private var closed = false

    /** Runs [body] with the live handle, or answers [fallback] once the driver is closed. */
    private inline fun <T> withHandle(fallback: T, body: (Long) -> T): T = synchronized(lock) {
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
        withHandle(0) { native.nativeRender(it, frameCount, left, right) }

    override fun close() = synchronized(lock) {
        if (closed) return@synchronized
        // Mark first, so nothing that later reads the flag can observe a handle that has already been released.
        closed = true
        native.synthRelease(handle)
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
