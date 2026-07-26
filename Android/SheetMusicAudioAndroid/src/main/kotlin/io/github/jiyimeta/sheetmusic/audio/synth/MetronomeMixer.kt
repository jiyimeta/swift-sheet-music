package io.github.jiyimeta.sheetmusic.audio.synth

import io.github.jiyimeta.sheetmusic.audio.model.MetronomeBeat

/**
 * Standalone beat scheduler backed by a dedicated [SynthDriver].
 *
 * The owning `AndroidPlaybackEngine` polls [updateCurrentTick] whenever
 * the MIDI player's tick advances, and folds this mixer's
 * [SynthDriver.writeFloat] output into the master sum buffer.
 *
 * ## Beat-crossing logic
 *
 * [updateCurrentTick] fires a noteOn/noteOff pair for every beat whose
 * tick falls strictly after the previous poll tick and at or before the
 * current tick. This ensures exactly-once delivery regardless of poll
 * granularity.
 *
 * ## GM percussion pitches
 *
 * MIDI channel 9 (0-indexed) is the GM percussion channel.
 * - Downbeat → high woodblock, pitch 76, velocity 96
 * - Upbeat   → low woodblock,  pitch 77, velocity 72
 *
 * FluidSynth handles overlapping noteOn/noteOff correctly, so we fire
 * the paired noteOff immediately after noteOn (stateless scheduler).
 */
internal class MetronomeMixer(
    val synth: SynthDriver,
    private val beats: List<MetronomeBeat>,
) {
    /** Whether the metronome clicks along with the music. Defaults to false. */
    var isEnabled: Boolean = false

    /**
     * Raised by the engine for the duration of a count-in, so the pre-roll is heard even with
     * [isEnabled] off — wanting a count-in but no click through the piece is a normal combination.
     *
     * `@Volatile` because the audio callback reads it (via [isAudible]) on a different thread from the
     * one that raises and lowers it.
     */
    @Volatile
    var isCountingIn: Boolean = false

    /**
     * Whether this mixer's synth output should be folded into the master buffer at all.
     *
     * The render loop skips the mix entirely when false, so anything fired while this is false is
     * silently discarded no matter what the synth did — which is exactly how a count-in with the
     * metronome switched off went inaudible.
     */
    val isAudible: Boolean get() = isEnabled || isCountingIn

    /**
     * Output volume of the metronome synth (range 0..1).
     * Applies via [SynthDriver.setGain].
     */
    var volume: Float = 1.0f
        set(value) {
            field = value
            synth.setGain(value)
        }

    /** GM percussion channel (0-indexed). */
    private val percussionChannel = 9

    /** High woodblock pitch — used for downbeats. */
    private val downbeatPitch = 76

    /** Low woodblock pitch — used for upbeats. */
    private val upbeatPitch = 77

    private var lastTick: Long = -1L

    /**
     * Called by the playback engine each time the player's tick advances.
     * Fires a noteOn+noteOff for every beat whose tick is in
     * (lastTick, currentTick].
     *
     * When [isEnabled] is false, no events are fired (lastTick is still
     * updated so the scheduler stays in sync with the player).
     */
    fun updateCurrentTick(tick: Long) {
        if (!isEnabled) {
            lastTick = tick
            return
        }
        for (b in beats) {
            if (b.tick in (lastTick + 1)..tick) fire(b)
        }
        lastTick = tick
    }

    /**
     * Fires one count-in click immediately, bypassing [updateCurrentTick]'s beat-crossing logic.
     *
     * The pre-roll happens BEFORE the MIDI player starts, so there is no player tick to drive the
     * scheduler with — the engine walks the count-in schedule on its own clock and calls this per beat.
     *
     * Deliberately ignores [isEnabled]: that flag is the user's *metronome* setting (click along with
     * the music), whereas a count-in is its own setting. Someone who wants a count-in but no metronome
     * through the piece must still hear the count.
     */
    fun fireCountInClick(isDownbeat: Boolean) {
        fire(MetronomeBeat(tick = 0, isDownbeat = isDownbeat))
    }

    private fun fire(b: MetronomeBeat) {
        val pitch = if (b.isDownbeat) downbeatPitch else upbeatPitch
        val velocity = if (b.isDownbeat) 96 else 72
        synth.noteOn(channel = percussionChannel, pitch = pitch, velocity = velocity)
        // Fire noteOff immediately — FluidSynth handles the voice release
        // envelope internally and tolerates immediate noteOff after noteOn.
        synth.noteOff(channel = percussionChannel, pitch = pitch)
    }
}
