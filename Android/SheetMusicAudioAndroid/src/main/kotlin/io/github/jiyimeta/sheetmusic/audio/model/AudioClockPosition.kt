package io.github.jiyimeta.sheetmusic.audio.model

/**
 * A playback position paired with the device's AUDIO clock.
 *
 * The engine's `currentTimeSeconds` / `currentCursor` flows are written from a 33 ms poll, so their
 * timestamp is the instant the POLL observed the transport — not the instant the audio was heard.
 * A host smoothing a playhead between polls therefore has nothing better than "the last value, plus
 * however long ago I happened to read it", and the error is the poll's own jitter.
 *
 * This read supplies the missing anchor: `framePosition` is the frame the output has actually
 * presented and `nanoTime` is the `System.nanoTime()` instant at which it did, both straight from
 * `AudioTrack.getTimestamp()`. Extrapolating from `nanoTime` rather than from the read's own return
 * instant removes the poll jitter from the estimate.
 *
 * Additive by design: nothing about the existing flows changes, and a host that ignores this keeps
 * exactly the behaviour it had.
 */
data class AudioClockPosition(
    /**
     * The transport's tick at the moment of the read, in the UNROLLED coordinates the player
     * reports — repeats and jumps expanded. This is the form `nativeSecondsAtTick` and
     * `nativeFrameAtTick` both take, so it can be converted without a second translation.
     *
     * Read a moment apart from [nanoTime] rather than simultaneously with it — the two come from
     * different subsystems and nothing can sample them atomically. The gap is one field read, far
     * below the poll interval this exists to improve on, but it is not zero.
     */
    val unrolledTick: Long,
    /** Frames the audio output has presented, from `AudioTimestamp.framePosition`. */
    val framePosition: Long,
    /** The `System.nanoTime()` instant at which [framePosition] was presented. */
    val nanoTime: Long,
)
