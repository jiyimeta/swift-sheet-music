package io.github.jiyimeta.sheetmusic.audio.synth

import io.github.jiyimeta.sheetmusic.audio.native.FluidSynthNative

/**
 * Thin wrapper over fluid_player_t. Owns the player handle.
 *
 * Per Phase 9 plan: the SMF passed to [load] has each event's channel
 * field rewritten to its track index by the Swift bridge
 * (AudioMidiBridge.relabelChannelsToTrackIndex). The
 * fluid_player_set_playback_callback hook will route events to the
 * matching per-staff fluid_synth based on event.channel. Wiring the
 * playback callback is Phase 10 work — for now PlayerDriver just
 * exposes load/play/stop/seek.
 *
 * Lifecycle: [load] → [play] → ([seekTick] | [stop]) → [close].
 * [close] is safe to call multiple times.
 */
internal class PlayerDriver(
    private val attachedSynthHandle: Long,
    private val nativeBindings: NativeBindings = ProductionBindings,
) : AutoCloseable {

    /**
     * Abstraction layer over FluidSynthNative for the player functions.
     * Implement with a fake in unit tests to record calls without
     * loading the native library.
     */
    interface NativeBindings {
        fun newPlayer(synthHandle: Long): Long
        fun deletePlayer(handle: Long)
        fun playerAddMem(handle: Long, bytes: ByteArray): Int
        fun playerPlay(handle: Long): Int
        fun playerStop(handle: Long): Int
        fun playerJoin(handle: Long): Int
        fun playerSeek(handle: Long, tick: Long): Int
        fun playerGetCurrentTick(handle: Long): Long
        fun playerSetTempo(handle: Long, type: Int, value: Double): Int
    }

    /** Production implementation — delegates directly to [FluidSynthNative]. */
    object ProductionBindings : NativeBindings {
        override fun newPlayer(synthHandle: Long) = FluidSynthNative.newPlayer(synthHandle)
        override fun deletePlayer(handle: Long) = FluidSynthNative.deletePlayer(handle)
        override fun playerAddMem(handle: Long, bytes: ByteArray) =
            FluidSynthNative.playerAddMem(handle, bytes)
        override fun playerPlay(handle: Long) = FluidSynthNative.playerPlay(handle)
        override fun playerStop(handle: Long) = FluidSynthNative.playerStop(handle)
        override fun playerJoin(handle: Long) = FluidSynthNative.playerJoin(handle)
        override fun playerSeek(handle: Long, tick: Long) =
            FluidSynthNative.playerSeek(handle, tick)
        override fun playerGetCurrentTick(handle: Long) =
            FluidSynthNative.playerGetCurrentTick(handle)
        override fun playerSetTempo(handle: Long, type: Int, value: Double) =
            FluidSynthNative.playerSetTempo(handle, type, value)
    }

    private var handle: Long = 0
    private var closed = false

    /**
     * Creates the native player handle and loads [smfBytes] into it.
     * Returns 0 on success or -1 if the native handle could not be created.
     * A previous load is replaced (caller should call [close] first).
     */
    fun load(smfBytes: ByteArray): Int {
        handle = nativeBindings.newPlayer(attachedSynthHandle)
        if (handle == 0L) return -1
        return nativeBindings.playerAddMem(handle, smfBytes)
    }

    /** Starts playback. Returns FluidSynth status code (0 = OK). */
    fun play(): Int = if (handle != 0L) nativeBindings.playerPlay(handle) else -1

    /** Stops playback. Returns FluidSynth status code (0 = OK). */
    fun stop(): Int = if (handle != 0L) nativeBindings.playerStop(handle) else -1

    /** Seeks to [tick]. Returns FluidSynth status code (0 = OK). */
    fun seekTick(tick: Long): Int =
        if (handle != 0L) nativeBindings.playerSeek(handle, tick) else -1

    /** Blocks until playback finishes. Returns FluidSynth status code (0 = OK). */
    fun join(): Int = if (handle != 0L) nativeBindings.playerJoin(handle) else -1

    /** Returns the player's current MIDI tick position, or 0 if not loaded. */
    val currentTick: Long
        get() = if (handle != 0L) nativeBindings.playerGetCurrentTick(handle) else 0

    /**
     * Sets a relative tempo scale on the player.
     * 1.0 = native tempo, 2.0 = double speed, 0.5 = half speed.
     * Returns FluidSynth status code (0 on success).
     *
     * Uses `FLUID_PLAYER_TEMPO_INTERNAL` (type=0) which scales the SMF's
     * tempo events. `FLUID_PLAYER_TEMPO_EXTERNAL_BPM/MIDI` would override
     * tempo absolutely — not what we want here.
     */
    fun setTempo(scale: Double): Int =
        if (handle != 0L) nativeBindings.playerSetTempo(handle, 0, scale) else -1

    /**
     * Stops playback, waits for the player thread, and releases the native
     * handle.  Safe to call multiple times.
     */
    override fun close() {
        if (closed) return
        if (handle != 0L) {
            try { nativeBindings.playerStop(handle) } catch (_: Throwable) {}
            try { nativeBindings.playerJoin(handle) } catch (_: Throwable) {}
            nativeBindings.deletePlayer(handle)
            handle = 0
        }
        closed = true
    }
}
