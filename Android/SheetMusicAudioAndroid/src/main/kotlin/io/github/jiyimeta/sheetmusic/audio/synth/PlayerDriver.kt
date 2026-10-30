package io.github.jiyimeta.sheetmusic.audio.synth

/**
 * The transport of one SMF on one synth: SwiftySynth's `MidiFileSequencer` behind a Swift `HostedSequence`, spoken to
 * in the SMF's own ticks. Owns the sequence handle.
 *
 * The SMF passed to [load] arrives with its channels already remapped on the Swift side: AudioMidiBridge.renderMidi
 * applies the deduped LiveChannelPlan via MidiChannelRemap, so each event's channel is the live mixer-strip channel.
 * The sequence drives the synth it is attached to; there is no per-staff synth routing and no playback callback. It
 * advances inside that synth's render, so it moves exactly as fast as the audio the output writer pulls.
 *
 * A synth has one transport at a time: loading a second sequence onto the same synth makes the first one inert.
 *
 * Lifecycle: [load] → [play] → ([seekTick] | [stop]) → [close]. [close] is safe to call multiple times, and every call
 * is taken under one lock and is a no-op once closed — the handle is a retained Swift object's address, and the poll
 * loop reads [currentTick] from another thread than the one that closes.
 */
internal class PlayerDriver(
    /** The synth the sequence plays on; null for a test player with no synth. */
    private val attachedSynth: SynthDriver?,
    private val nativeBindings: NativeBindings = ProductionBindings,
) : AutoCloseable {

    /**
     * The native sequence functions. Implement with a fake in unit tests to record calls without loading the native
     * library.
     */
    interface NativeBindings {
        /** A sequence over [bytes] attached to [synth]; 0 when it is closed or the bytes are not an SMF. */
        fun newPlayer(synth: SynthDriver?, bytes: ByteArray): Long
        fun deletePlayer(handle: Long)
        fun playerPlay(handle: Long)
        fun playerStop(handle: Long)
        fun playerSeek(handle: Long, tick: Long)
        fun playerGetCurrentTick(handle: Long): Long
        /** Scales the tempo: 1.0 is the SMF's own, 2.0 twice as fast. */
        fun playerSetTempo(handle: Long, scale: Double)
    }

    /** Production implementation — the Swift `HostedSequence` behind [SwiftySynthNative]. */
    object ProductionBindings : NativeBindings {
        override fun newPlayer(synth: SynthDriver?, bytes: ByteArray) = synth?.attachSequence(bytes) ?: 0L
        override fun deletePlayer(handle: Long) = SwiftySynthNative.sequenceRelease(handle)
        override fun playerPlay(handle: Long) = SwiftySynthNative.sequencePlay(handle)
        override fun playerStop(handle: Long) = SwiftySynthNative.sequenceStop(handle)
        override fun playerSeek(handle: Long, tick: Long) = SwiftySynthNative.sequenceSeek(handle, tick)
        override fun playerGetCurrentTick(handle: Long) = SwiftySynthNative.sequenceCurrentTick(handle)
        override fun playerSetTempo(handle: Long, scale: Double) = SwiftySynthNative.sequenceSetSpeed(handle, scale)
    }

    private val lock = Any()
    private var handle: Long = 0
    private var closed = false

    /** Runs [body] with the live handle, or answers [fallback] when nothing is loaded or the driver is closed. */
    private inline fun <T> withHandle(fallback: T, body: (Long) -> T): T = synchronized(lock) {
        if (closed || handle == 0L) fallback else body(handle)
    }

    /**
     * Attaches [smfBytes] to the synth, parked at its start and not playing. Returns 0 on success or -1 when the bytes
     * are not an SMF (or the driver is closed). A previous load is released first.
     */
    fun load(smfBytes: ByteArray): Int = synchronized(lock) {
        if (closed) return@synchronized -1
        if (handle != 0L) nativeBindings.deletePlayer(handle)
        handle = nativeBindings.newPlayer(attachedSynth, smfBytes)
        if (handle == 0L) -1 else 0
    }

    /** Starts (or resumes) playback from where the transport stands. Returns 0, or -1 when nothing is loaded. */
    fun play(): Int = withHandle(-1) { nativeBindings.playerPlay(it); 0 }

    /** Stops playback where it stands and cuts the synth's sounding voices. Returns 0, or -1 when nothing is loaded. */
    fun stop(): Int = withHandle(-1) { nativeBindings.playerStop(it); 0 }

    /** Moves the transport to [tick] at once; [currentTick] reads it back. Returns 0, or -1 when nothing is loaded. */
    fun seekTick(tick: Long): Int = withHandle(-1) { nativeBindings.playerSeek(it, tick); 0 }

    /** The transport's current MIDI tick position, or 0 if not loaded. */
    val currentTick: Long
        get() = withHandle(0L) { nativeBindings.playerGetCurrentTick(it) }

    /**
     * Sets a relative tempo scale: 1.0 = native tempo, 2.0 = double speed, 0.5 = half speed. Returns 0, or -1 when
     * nothing is loaded.
     */
    fun setTempo(scale: Double): Int = withHandle(-1) { nativeBindings.playerSetTempo(it, scale); 0 }

    /** Stops playback and releases the sequence. Safe to call multiple times. */
    override fun close() = synchronized(lock) {
        if (closed) return@synchronized
        closed = true
        if (handle != 0L) {
            try { nativeBindings.playerStop(handle) } catch (_: Throwable) {}
            nativeBindings.deletePlayer(handle)
            handle = 0
        }
    }
}
