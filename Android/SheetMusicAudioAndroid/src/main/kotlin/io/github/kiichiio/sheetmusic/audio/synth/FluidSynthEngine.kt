package io.github.kiichiio.sheetmusic.audio.synth

import android.content.Context
import io.github.kiichiio.sheetmusic.audio.SoundfontResolver
import io.github.kiichiio.sheetmusic.audio.model.StaffParams

/**
 * Single [SynthDriver] owner. Channels 0..N-1 are assigned 1:1 to staves
 * (maximum 16 staves, matching the MIDI channel limit).
 *
 * Per-staff volume / mute / solo is implemented via MIDI CC7 (channel volume)
 * on the shared synth, so the fluid_player's default channel routing drives
 * playback directly — no playback-callback shim required.
 *
 * Inject [synthFactory] to supply a fake [SynthDriver] in unit tests —
 * production code leaves this at the default which creates a
 * [FluidSynthDriver].
 */
internal class FluidSynthEngine(
    private val synthFactory: (sampleRate: Int) -> SynthDriver = { sr ->
        FluidSynthDriver.create(sr)
    },
) {
    private var synth: SynthDriver? = null
    private var staffCountValue: Int = 0

    val staffCount: Int get() = staffCountValue

    /** Native fluid_synth_t handle, or 0L if no synth is loaded. */
    val synthHandle: Long get() = synth?.nativeHandle ?: 0L

    /**
     * Creates ONE [SynthDriver] for all staves. Each staff is assigned to
     * MIDI channel [StaffParams.staffIndex]. The GM SoundFont is loaded
     * once; per-staff programs are selected via [SynthDriver.programSelect].
     *
     * Any existing state is torn down first via [teardown].
     *
     * [context] is declared nullable so that JVM unit tests can pass null
     * without triggering Kotlin null-check intrinsics. Production callers
     * always supply a real Context; fakes never dereference it.
     */
    fun setupStaves(
        params: List<StaffParams>,
        resolver: SoundfontResolver,
        context: Context?,
        sampleRate: Int = 48_000,
    ) {
        teardown()
        require(params.size <= 16) { "Single-synth backend supports at most 16 staves" }
        if (params.isEmpty()) return

        val driver = synthFactory(sampleRate)

        // Load the default GM SF2 once; resolve the URI via defaultGmSoundfontUri
        // first, falling back to a per-staff lookup for the first staff.
        val uri = resolver.defaultGmSoundfontUri
            ?: resolver.soundfontUriFor(params[0].bankLSB, params[0].program, params[0].isDrums)
        val sfid = driver.loadSoundFont(uri, context)

        if (sfid >= 0) {
            for (p in params) {
                driver.programSelect(
                    sfid = sfid,
                    channel = p.staffIndex,
                    bank = p.bankLSB,
                    program = p.program,
                )
            }
        }
        // Staff is silent (sfid < 0 or uri was null) but the channel routing is
        // still correct — fluid_player replays events on the relabeled channels.
        synth = driver
        staffCountValue = params.size
    }

    /** Sets MIDI CC7 (channel volume) on the channel for [staffIndex] (range 0..1). */
    fun setChannelVolume(staffIndex: Int, volume: Float) {
        if (staffIndex !in 0 until staffCountValue) return
        val cc = (volume.coerceIn(0f, 1f) * 127).toInt()
        synth?.cc(channel = staffIndex, controller = 7, value = cc)
    }

    /** Silences channel [staffIndex] via CC7=0 + allNotesOff. */
    fun muteChannel(staffIndex: Int) {
        if (staffIndex !in 0 until staffCountValue) return
        synth?.cc(channel = staffIndex, controller = 7, value = 0)
        synth?.allNotesOff(staffIndex)
    }

    /** Fires noteOn on [staffIndex]'s channel. */
    fun previewNoteOn(staffIndex: Int, pitch: Int, velocity: Int) {
        synth?.noteOn(staffIndex, pitch, velocity)
    }

    /** Fires noteOff on [staffIndex]'s channel. */
    fun previewNoteOff(staffIndex: Int, pitch: Int) {
        synth?.noteOff(staffIndex, pitch)
    }

    /** Sends allNotesOff to every staff channel. */
    fun allNotesOff() {
        for (ch in 0 until staffCountValue) synth?.allNotesOff(ch)
    }

    /**
     * Renders [frameCount] stereo float samples from the shared synth into
     * [left] / [right]. Zeroes the buffers if no synth is loaded.
     */
    fun writeFloat(frameCount: Int, left: FloatArray, right: FloatArray) {
        val s = synth
        if (s == null) {
            for (i in 0 until frameCount) { left[i] = 0f; right[i] = 0f }
            return
        }
        s.writeFloat(frameCount, left, right)
    }

    /** Closes the synth driver and resets state. */
    fun teardown() {
        synth?.close()
        synth = null
        staffCountValue = 0
    }
}
