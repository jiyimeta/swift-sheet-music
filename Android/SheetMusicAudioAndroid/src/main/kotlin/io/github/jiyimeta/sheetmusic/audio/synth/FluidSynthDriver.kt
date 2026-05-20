package io.github.jiyimeta.sheetmusic.audio.synth

import android.content.Context
import android.net.Uri
import io.github.jiyimeta.sheetmusic.audio.AudioBackendException
import io.github.jiyimeta.sheetmusic.audio.native.FluidSynthNative

/**
 * Production [SynthDriver] — wraps a single fluid_synth_t handle.
 *
 * Use [FluidSynthDriver.create] to construct; constructor is private
 * to guarantee the handle is valid.
 */
internal class FluidSynthDriver private constructor(
    private val handle: Long,
) : SynthDriver {

    override val nativeHandle: Long get() = handle
    private var closed = false

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
        return FluidSynthNative.sfload(handle, path, resetPresets = true)
    }

    override fun programSelect(sfid: Int, channel: Int, bank: Int, program: Int) {
        FluidSynthNative.programSelect(handle, channel, sfid, bank, program)
    }

    override fun setGain(value: Float) = FluidSynthNative.setGain(handle, value)

    override fun cc(channel: Int, controller: Int, value: Int) {
        FluidSynthNative.cc(handle, channel, controller, value)
    }

    override fun getCC(channel: Int, controller: Int): Int =
        FluidSynthNative.getCC(handle, channel, controller)

    override fun setChannelType(channel: Int, isDrum: Boolean) {
        FluidSynthNative.setChannelType(handle, channel, if (isDrum) 1 else 0)
    }

    override fun noteOn(channel: Int, pitch: Int, velocity: Int) {
        FluidSynthNative.noteOn(handle, channel, pitch, velocity)
    }

    override fun noteOff(channel: Int, pitch: Int) {
        FluidSynthNative.noteOff(handle, channel, pitch)
    }

    override fun allNotesOff(channel: Int) {
        FluidSynthNative.allNotesOff(handle, channel)
    }

    override fun handleMidiEvent(rawEvent: Long) {
        // The MIDI event reaches us packed; unpack the conventional
        // 4-byte SMF-style word and re-dispatch via fluid_synth note/cc/etc.
        // For now we route the most common shapes — noteOn/noteOff/cc.
        // The packing format is defined by AndroidPlaybackEngine's
        // PlayerDriver callback (Phase 9 Task 34); for now this
        // method is a stub that subclasses can override or that the
        // Phase 10 wiring fills in. Defer the real implementation
        // until the player callback shape is concrete.
    }

    override fun writeFloat(frameCount: Int, left: FloatArray, right: FloatArray): Int =
        FluidSynthNative.writeFloat(handle, frameCount, left, right)

    override fun close() {
        if (closed) return
        FluidSynthNative.deleteSynth(handle)
        closed = true
    }

    private fun materializeUriToCache(uri: Uri, context: Context): String? {
        // Content URI → app cacheDir/sf2-cache/<hash>.sf2
        return try {
            val inStream = context.contentResolver.openInputStream(uri) ?: return null
            val cacheDir = java.io.File(context.cacheDir, "sf2-cache")
            cacheDir.mkdirs()
            val target = java.io.File(cacheDir, "sf-${uri.hashCode()}.sf2")
            if (!target.exists() || target.length() == 0L) {
                target.outputStream().use { out -> inStream.copyTo(out) }
            }
            inStream.close()
            target.absolutePath
        } catch (e: Exception) {
            null
        }
    }
}
