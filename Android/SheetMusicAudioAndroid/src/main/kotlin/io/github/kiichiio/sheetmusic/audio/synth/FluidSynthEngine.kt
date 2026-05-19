package io.github.kiichiio.sheetmusic.audio.synth

import android.content.Context
import io.github.kiichiio.sheetmusic.audio.SoundfontResolver
import io.github.kiichiio.sheetmusic.audio.model.StaffParams

/**
 * One [SynthDriver] per staff. Per-staff volume / mute / solo is
 * implemented as per-synth gain control.
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
    private val staves = mutableListOf<SynthDriver>()

    val staffCount: Int get() = staves.size

    /**
     * Creates one [SynthDriver] per entry in [params], loads the
     * appropriate SoundFont from [resolver], and programs the first
     * channel.
     *
     * Any existing staves are torn down first via [teardown].
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
        for (p in params) {
            val driver = synthFactory(sampleRate)
            // Resolve the SoundFont URI; may be null if no resolver provides one.
            // In that case loadSoundFont returns -1 and the staff stays silent.
            val uri = resolver.soundfontUriFor(p.bankLSB, p.program, p.isDrums)
                ?: resolver.defaultGmSoundfontUri
            val sfid = driver.loadSoundFont(uri, context)
            if (sfid >= 0) {
                driver.programSelect(sfid, channel = 0, bank = p.bankLSB, program = p.program)
            }
            // Staff is silent (sfid < 0 or uri was null) but still appears in the
            // routing graph so channel addressing stays consistent.
            staves += driver
        }
    }

    /** Sets the gain on the [SynthDriver] at [idx]. No-op if out of range. */
    fun setStaffGain(idx: Int, gain: Float) {
        if (idx in staves.indices) staves[idx].setGain(gain)
    }

    /** Returns the [SynthDriver] for [idx], or null if out of range. */
    fun staff(idx: Int): SynthDriver? = staves.getOrNull(idx)

    /** Sends allNotesOff(channel = -1) to every staff. */
    fun allNotesOff() {
        staves.forEach { it.allNotesOff(channel = -1) }
    }

    /**
     * Mixes all non-muted staves into [left] / [right].
     *
     * The output buffers are zeroed first. Each non-muted driver renders
     * into temporary per-staff buffers, which are then accumulated into
     * the output in a single pass.
     *
     * @param effectiveMutes per-staff mute flags; if index is out of
     *   bounds the staff is treated as audible (not muted).
     */
    fun writeMixedFloat(
        frameCount: Int,
        left: FloatArray,
        right: FloatArray,
        effectiveMutes: BooleanArray,
    ) {
        for (i in 0 until frameCount) { left[i] = 0f; right[i] = 0f }
        val staffLeft = FloatArray(frameCount)
        val staffRight = FloatArray(frameCount)
        for ((i, driver) in staves.withIndex()) {
            if (i < effectiveMutes.size && effectiveMutes[i]) continue
            driver.writeFloat(frameCount, staffLeft, staffRight)
            for (j in 0 until frameCount) {
                left[j] += staffLeft[j]
                right[j] += staffRight[j]
            }
        }
    }

    /** Closes all synth drivers and clears the staff list. */
    fun teardown() {
        staves.forEach { it.close() }
        staves.clear()
    }
}
