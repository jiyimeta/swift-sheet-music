package io.github.jiyimeta.sheetmusic.audio.synth

import android.content.Context
import io.github.jiyimeta.sheetmusic.audio.SoundfontResolver
import io.github.jiyimeta.sheetmusic.audio.model.StaffParams

/**
 * Single [SynthDriver] owner. Historically channels 0..N-1 were assigned 1:1
 * to staves; since the live-channel-plan mixer (per-(part × instrument) strip
 * dedup — see `AndroidPlaybackEngine.prepare`), [setupStaves] is called with
 * one entry PER STRIP, keyed on its LIVE MIDI channel — which may be sparse
 * (e.g. a 2-strip score where one strip is the drum channel 9) rather than a
 * dense `0 until count` range. Every method here therefore gates on whether
 * [staffLoadParams] has an entry for the given channel, not on `channel <
 * staffCount` — that bound was only ever correct for the dense case.
 * Parameters are still named `staffIndex` for source compatibility, but the
 * value passed is a raw MIDI channel number (`0...15`), not necessarily this
 * staff's own array position (maximum 16 channels, matching the MIDI limit).
 *
 * Per-channel volume / mute / solo is implemented via MIDI CC7 (channel
 * volume) on the shared synth, so the fluid_player's default channel routing
 * drives playback directly — no playback-callback shim required.
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

    /**
     * Resolved soundfont + bank parameters captured at [setupStaves] time for
     * a single staff channel. [effectiveBank] is already the effective bank: drum staves
     * store 128 here so [setStaffProgram] doesn't need to re-branch on [isDrums].
     */
    private data class StaffLoadParams(val effectiveBank: Int, val isDrums: Boolean)

    private var synth: SynthDriver? = null
    private var staffCountValue: Int = 0

    /** sfid returned by [SynthDriver.loadSoundFont] at last [setupStaves]; -1 if none loaded. */
    private var loadedSfid: Int = -1

    /** Per-channel load parameters populated by [setupStaves]; null for unassigned channels. */
    private val staffLoadParams: Array<StaffLoadParams?> = arrayOfNulls(16)

    val staffCount: Int get() = staffCountValue

    /** Native fluid_synth_t handle, or 0L if no synth is loaded. */
    val synthHandle: Long get() = synth?.nativeHandle ?: 0L

    // ── CC7 round-trip state (Bug 2) ─────────────────────────────────

    /**
     * Per-channel remembered CC7 value. Updated when:
     * - setupStaves runs (initialized to GM default 100)
     * - muteChannel captures the live CC7 from the driver before silencing
     * - setChannelVolume records the user's explicit slider value
     *
     * On unmute, this value is restored so the channel returns to whatever
     * volume was last active (SMF-emitted or user-set), not the mixer
     * slider default of 127.
     */
    private val rememberedCC7 = IntArray(16) { 100 }

    /**
     * Whether the channel is currently muted (CC7 = 0). Used to suppress
     * the setChannelVolume write during active mute so SMF-emitted CC7
     * changes while muted are still remembered via the next muteChannel call.
     */
    private val channelMuted = BooleanArray(16) { false }

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
            ?: resolver.soundfontUriFor(params[0].bankLSB.toInt(), params[0].program.toInt(), params[0].isDrums)
        val sfid = driver.loadSoundFont(uri, context)
        loadedSfid = sfid

        // Populate per-staff load params (resolved bank: drums use 128, melodic use bankLSB).
        for (p in params) {
            val resolvedBank = if (p.isDrums) 128 else p.bankLSB.toInt()
            staffLoadParams[p.staffIndex] = StaffLoadParams(effectiveBank = resolvedBank, isDrums = p.isDrums)
        }

        if (sfid >= 0) {
            for (p in params) {
                if (p.isDrums) {
                    // Bug 1 fix: lock the channel into drum semantics so FluidSynth
                    // treats it as a percussion channel regardless of the channel number.
                    driver.setChannelType(p.staffIndex, isDrum = true)
                }
                val resolved = staffLoadParams[p.staffIndex] ?: continue
                driver.programSelect(
                    sfid = sfid,
                    channel = p.staffIndex,
                    bank = resolved.effectiveBank,
                    program = p.program.toInt().coerceIn(0, 127),
                )
            }
        }
        // Staff is silent (sfid < 0 or uri was null) but the channel routing is
        // still correct — fluid_player replays events on the relabeled channels.

        // Reset CC7 round-trip state for all channels (Bug 2).
        for (i in 0 until 16) {
            rememberedCC7[i] = 100  // GM default channel volume
            channelMuted[i] = false
        }

        synth = driver
        staffCountValue = params.size
    }

    /**
     * Sets MIDI CC7 (channel volume) on the channel for [staffIndex] (range 0..1).
     * Records the value in [rememberedCC7] so it can be restored after unmute.
     * If the channel is currently muted, the CC7 write is deferred — the value
     * is still stored and will be applied by [unmuteChannel].
     */
    fun setChannelVolume(staffIndex: Int, volume: Float) {
        if (staffLoadParams.getOrNull(staffIndex) == null) return
        val cc = (volume.coerceIn(0f, 1f) * 127).toInt()
        rememberedCC7[staffIndex] = cc
        if (!channelMuted[staffIndex]) {
            synth?.cc(channel = staffIndex, controller = 7, value = cc)
        }
    }

    /**
     * Silences channel [staffIndex] via CC7=0 + allNotesOff.
     *
     * Captures the channel's live CC7 from the driver before silencing it, so
     * SMF-emitted volume changes are round-tripped correctly on unmute. If
     * already muted, the live CC7 snapshot is skipped to avoid overwriting the
     * value captured at the first mute.
     */
    fun muteChannel(staffIndex: Int) {
        if (staffLoadParams.getOrNull(staffIndex) == null) return
        // Capture the current live CC7 (may have been updated by SMF events or
        // user slider) before we zero it.
        if (!channelMuted[staffIndex]) {
            val liveCC7 = synth?.getCC(staffIndex, 7) ?: -1
            if (liveCC7 >= 0) rememberedCC7[staffIndex] = liveCC7
        }
        channelMuted[staffIndex] = true
        synth?.cc(channel = staffIndex, controller = 7, value = 0)
        synth?.allNotesOff(staffIndex)
    }

    /**
     * Restores channel [staffIndex] to its last-known CC7 value.
     *
     * The restored value is whatever CC7 was captured at the time of mute —
     * either the SMF-emitted volume or the user's slider value. This prevents
     * unmute from snapping the volume to 127 (the mixer slider default) when
     * the SMF had previously written a different CC7.
     */
    fun unmuteChannel(staffIndex: Int) {
        if (staffLoadParams.getOrNull(staffIndex) == null) return
        channelMuted[staffIndex] = false
        synth?.cc(channel = staffIndex, controller = 7, value = rememberedCC7[staffIndex])
    }

    /**
     * Changes the instrument program on [staffIndex]'s channel at runtime.
     *
     * Uses the soundfont id and bank captured during [setupStaves] so the caller
     * only needs to supply the new GM program number (0–127).
     * Out-of-range [program] values are clamped to [0, 127].
     * No-ops if [setupStaves] has not been called, if the sfid is invalid, or if
     * [staffIndex] is outside [0, staffCount).
     */
    fun setStaffProgram(staffIndex: Int, program: Int) {
        val params = staffLoadParams.getOrNull(staffIndex) ?: return
        if (loadedSfid < 0) return
        val s = synth ?: return
        val clamped = program.coerceIn(0, 127)
        s.programSelect(
            sfid = loadedSfid,
            channel = staffIndex,
            bank = params.effectiveBank,
            program = clamped,
        )
    }

    /**
     * Retune every melodic staff channel by [cents] off A4=440 via MIDI Master
     * Tuning RPN (FluidSynth honors it). Drum channels stay at concert pitch.
     */
    fun setMasterTuning(cents: Double) {
        val s = synth ?: return
        val rpn = MasterTuning.rpnControlChanges(cents)
        // Iterate CONFIGURED channels, not `0 until staffCountValue` — with
        // live-channel-keyed setup the configured channel numbers may be
        // sparse (e.g. a drum strip on channel 9 while only 2 strips exist).
        for (ch in staffLoadParams.indices) {
            val params = staffLoadParams[ch] ?: continue
            if (params.isDrums) continue
            for (cc in rpn) s.cc(ch, cc.controller, cc.value)
        }
    }

    /** Fires noteOn on [staffIndex]'s channel. */
    fun previewNoteOn(staffIndex: Int, pitch: Int, velocity: Int) {
        synth?.noteOn(staffIndex, pitch, velocity)
    }

    /** Fires noteOff on [staffIndex]'s channel. */
    fun previewNoteOff(staffIndex: Int, pitch: Int) {
        synth?.noteOff(staffIndex, pitch)
    }

    /** Sends allNotesOff to every configured channel (may be sparse — see class doc). */
    fun allNotesOff() {
        for (ch in staffLoadParams.indices) if (staffLoadParams[ch] != null) synth?.allNotesOff(ch)
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
        loadedSfid = -1
        staffLoadParams.fill(null)
        for (i in 0 until 16) {
            rememberedCC7[i] = 100
            channelMuted[i] = false
        }
    }
}
