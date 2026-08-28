package io.github.jiyimeta.sheetmusic.audio.synth

import android.content.Context
import android.content.res.AssetFileDescriptor
import android.net.Uri
import io.github.jiyimeta.sheetmusic.audio.AudioBackendException
import io.github.jiyimeta.sheetmusic.audio.native.FluidSynthNative

/**
 * Production [SynthDriver] — wraps a single fluid_synth_t handle.
 *
 * Use [FluidSynthDriver.create] to construct; constructor is private
 * to guarantee the handle is valid.
 *
 * **Every native call is taken under [lock], and a closed driver is inert rather than fatal.** `close()` used to
 * `fluid_delete_synth` the handle and set a `closed` flag that nothing else read, so the handle stayed in the field
 * and every other method went on passing a freed `fluid_synth_t*` into C. That is not a "stale synth plays nothing"
 * bug — it is a write through freed memory, and the damage lands wherever the allocator has since handed that
 * address out, not here.
 *
 * The flag alone cannot fix it, because the caller that loses is not the one that misordered its calls: teardown
 * runs from a `prepare` coroutine while `AndroidPlaybackEngine.stop` reaches `allNotesOff` from the main thread,
 * so a check-then-call would still be closed in the window between the two. The lock is what makes "closed" mean
 * anything, and it also serializes `close` against a call already in flight.
 *
 * A host that only tears playback down on leaving the score barely touches this window. One that re-prepares per
 * edit — which is what note editing does — walks through it on every keystroke. Same lifetime hole `OboeStream.stop`
 * had (2.0.1), one object over.
 *
 * **Found while chasing a heap corruption that turned out to be something else** (a stale SwiftPM build on the host
 * side, producing a mixed `.so`), and fixing this did not change that crash's reproduction rate. It is a real defect
 * on its own terms; do not read it as the explanation for any particular crash report.
 */
internal class FluidSynthDriver private constructor(
    private val handle: Long,
) : SynthDriver {

    override val nativeHandle: Long get() = handle
    private val lock = Any()
    private var closed = false

    /**
     * Runs [body] with the live handle, or answers [fallback] once the driver is closed.
     *
     * Held for the duration of the native call on purpose — see the class doc: releasing before the call is what
     * leaves the use-after-free window open.
     */
    private inline fun <T> withHandle(fallback: T, body: (Long) -> T): T = synchronized(lock) {
        if (closed) fallback else body(handle)
    }

    companion object {
        fun create(sampleRate: Int): FluidSynthDriver {
            val handle = FluidSynthNative.newSynth(sampleRate)
            if (handle == 0L) {
                throw AudioBackendException.FluidSynthInit("newSynth returned 0")
            }
            return FluidSynthDriver(handle)
        }
    }

    override fun loadSoundFont(uri: Uri?, context: Context?): Int {
        if (uri == null || context == null) return -1
        val path = materializeUriToCache(uri, context) ?: return -1
        return withHandle(-1) { FluidSynthNative.sfload(it, path, resetPresets = true) }
    }

    override fun programSelect(sfid: Int, channel: Int, bank: Int, program: Int) {
        withHandle(Unit) { FluidSynthNative.programSelect(it, channel, sfid, bank, program) }
    }

    override fun setGain(value: Float) = withHandle(Unit) { FluidSynthNative.setGain(it, value) }

    override fun cc(channel: Int, controller: Int, value: Int) {
        withHandle(Unit) { FluidSynthNative.cc(it, channel, controller, value) }
    }

    override fun getCC(channel: Int, controller: Int): Int =
        withHandle(0) { FluidSynthNative.getCC(it, channel, controller) }

    override fun setChannelType(channel: Int, isDrum: Boolean) {
        withHandle(Unit) { FluidSynthNative.setChannelType(it, channel, if (isDrum) 1 else 0) }
    }

    override fun noteOn(channel: Int, pitch: Int, velocity: Int) {
        withHandle(Unit) { FluidSynthNative.noteOn(it, channel, pitch, velocity) }
    }

    override fun noteOff(channel: Int, pitch: Int) {
        withHandle(Unit) { FluidSynthNative.noteOff(it, channel, pitch) }
    }

    override fun allNotesOff(channel: Int) {
        withHandle(Unit) { FluidSynthNative.allNotesOff(it, channel) }
    }

    override fun handleMidiEvent(rawEvent: Long) {
        // Intentionally inert. Production playback never routes events
        // through here: the SMF player is attached directly to the single
        // synth handle, so FluidSynth dispatches player events natively.
        // Nothing calls this method outside test fakes; it exists only to
        // satisfy the [SynthDriver] interface.
    }

    /**
     * Renders into [left] / [right], or leaves them untouched and reports 0 frames once closed.
     *
     * This one runs on the audio callback, so the lock here is the one worth justifying: it is uncontended in the
     * steady state (only `close` ever takes it against a render), and the alternative it replaces was rendering
     * from a freed synth.
     */
    override fun writeFloat(frameCount: Int, left: FloatArray, right: FloatArray): Int =
        withHandle(0) { FluidSynthNative.writeFloat(it, frameCount, left, right) }

    override fun close() = synchronized(lock) {
        if (closed) return@synchronized
        // Order matters even under the lock: mark first, so nothing that later reads the flag can observe a handle
        // that has already been deleted.
        closed = true
        FluidSynthNative.deleteSynth(handle)
    }

    private fun materializeUriToCache(uri: Uri, context: Context): String? {
        // Content URI → app cacheDir/sf2-cache/<hash>.sf2
        return try {
            val cacheDir = java.io.File(context.cacheDir, "sf2-cache")
            cacheDir.mkdirs()
            val target = java.io.File(cacheDir, "sf-${uri.hashCode()}.sf2")
            // The cache key is the URI, but the bytes behind a URI can change
            // — a host restages its SoundFont and the URI stays identical.
            // Compare lengths so a swap is actually noticed; see
            // `soundFontCacheIsStale`.
            val sourceLength = try {
                context.contentResolver.openAssetFileDescriptor(uri, "r").use {
                    it?.length ?: AssetFileDescriptor.UNKNOWN_LENGTH
                }
            } catch (_: Exception) {
                AssetFileDescriptor.UNKNOWN_LENGTH
            }
            if (soundFontCacheIsStale(target.exists(), target.length(), sourceLength)) {
                val inStream = context.contentResolver.openInputStream(uri) ?: return null
                inStream.use { input ->
                    target.outputStream().use { out -> input.copyTo(out) }
                }
            }
            target.absolutePath
        } catch (e: Exception) {
            null
        }
    }
}

/**
 * Whether the cached SoundFont copy must be re-materialized from its source.
 *
 * `materializeUriToCache` keys its cache on the URI alone. A URI does not
 * change when the host swaps the file behind it — an app that ships its
 * SoundFont as an asset hands out the same `file://…/gm.sf2` every run — so
 * refreshing only when the copy was missing or empty served stale bytes
 * forever, surviving every reinstall. Comparing lengths is what makes a
 * swap visible.
 *
 * [sourceLength] is [AssetFileDescriptor.UNKNOWN_LENGTH] when the provider
 * does not report one. In that case the existing copy is kept: re-copying
 * on every launch would make each start pay a multi-hundred-megabyte copy,
 * and the length check still covers every provider that does report one.
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
