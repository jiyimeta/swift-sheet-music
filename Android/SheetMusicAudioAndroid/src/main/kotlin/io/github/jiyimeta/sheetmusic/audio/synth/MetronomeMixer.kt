package io.github.jiyimeta.sheetmusic.audio.synth

/**
 * The metronome voice: a dedicated [SynthDriver] plus its own [PlayerDriver], playing a metronome-only SMF
 * (the score's tempo map + the click track) that the Swift bridge renders alongside the score's.
 *
 * ## Why a second player
 *
 * The clicks are MIDI events on a real transport, not notes the engine places by hand. A `fluid_player`
 * advances inside its synth's render call, so as long as both synths are asked for the same frame count
 * each audio callback and both sequences carry the same tempo map, the click lands on the same sample as
 * the note it marks. Firing clicks by hand instead — as this class used to, from the UI poll loop for the
 * body and from a wall-clock wait for the count-in — quantized every beat to whichever output buffer
 * happened to pick the note up, which is audible as an unsteady click, and dropped beats whenever a seek
 * or a stop left the hand-run cursor ahead of the player. Mirrors the Apple `SwiftySynthBackend`, which
 * runs its metronome on a second `MidiFileSequencer` for the same reasons.
 *
 * The count-in rides on this same transport: [loadSequence] swaps in a sequence whose clicks fill the
 * pre-roll region ahead of the shifted body, and the engine starts the score's player when this one
 * reaches the pre-roll's last tick.
 *
 * ## Freezing while inaudible
 *
 * While the metronome is neither enabled nor counting in, the engine skips rendering this synth entirely,
 * so its transport freezes and the click costs no CPU. [resyncTo] puts it back on the beat when it becomes
 * audible again — the same freeze-and-reseek discipline the Apple backend uses.
 *
 * ## GM percussion pitches
 *
 * MIDI channel 9 (0-indexed) is the GM percussion channel; the click track uses high woodblock (76) for
 * downbeats and low woodblock (77) for the rest. Both the pitches and the velocities come from the shared
 * `MetronomeSequenceBuilder`, so iOS and Android click identically.
 */
internal class MetronomeMixer(
    val synth: SynthDriver,
    /**
     * Builds a transport over the given click sequence, or returns null if it cannot be loaded (an older
     * native library that renders no metronome sequence, a score with no beats). With no transport every
     * call below no-ops and the metronome is simply silent — what the engine did before it had a click
     * track at all.
     */
    private val playerFor: (ByteArray) -> PlayerDriver?,
) {
    private var player: PlayerDriver? = null

    /** Tempo scale to re-apply whenever a new sequence is loaded; see [setTempo]. */
    private var tempoScale: Double = 1.0

    /**
     * Replaces the click sequence — the engine swaps between the plain body sequence and the one with a
     * count-in in front, which it can only build once it knows where playback starts.
     */
    fun loadSequence(smf: ByteArray) {
        player?.close()
        player = if (smf.isEmpty()) null else playerFor(smf)
        if (tempoScale != 1.0) player?.setTempo(tempoScale)
    }

    /** The click transport's position, in its own sequence's ticks. */
    val currentTick: Long get() = player?.currentTick ?: 0L
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
     * Whether this mixer's synth should be rendered and folded into the master buffer at all.
     *
     * The render loop skips it entirely when false, so anything the synth was told to play while this is
     * false is silently discarded — which is exactly how a count-in with the metronome switched off went
     * inaudible. It also means the click transport does not advance while false; see [resyncTo].
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

    /**
     * Starts the click transport at [tick] — call in lockstep with the score player's own start.
     * Also revives a transport that already ran off the end of the click track, which a bare
     * [seekTick] cannot do.
     */
    fun start(tick: Long) {
        val p = player ?: return
        seekTick(tick)
        p.play()
    }

    /** Stops the click transport and silences any ringing click. */
    fun stop() {
        player?.stop()
        synth.allNotesOff(percussionChannel)
    }

    /** Moves the click transport to [tick]. Mirror every score-player seek with this. */
    fun seekTick(tick: Long) {
        player?.seekTick(tick)
        synth.allNotesOff(percussionChannel)
    }

    /**
     * Scales the click transport's tempo, exactly as the score player's rate is scaled. Remembered so a
     * sequence loaded later starts out at the same rate — including the count-in's, which must count at
     * the tempo the music will actually play at.
     */
    fun setTempo(scale: Double) {
        tempoScale = scale
        player?.setTempo(scale)
    }

    /**
     * Puts the click transport back on [tick] after a stretch of being inaudible (during which it was not
     * rendered, so it did not advance). Cheap enough to call on every transition into audibility.
     */
    fun resyncTo(tick: Long) {
        player?.seekTick(tick)
    }

    /** Releases the click transport and its synth. */
    fun close() {
        try { player?.close() } catch (_: Throwable) {}
        try { synth.close() } catch (_: Throwable) {}
    }
}
