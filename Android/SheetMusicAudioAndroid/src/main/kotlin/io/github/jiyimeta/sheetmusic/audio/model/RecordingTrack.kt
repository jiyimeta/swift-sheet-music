package io.github.jiyimeta.sheetmusic.audio.model

/**
 * One recording on the engine's mixer: a decoded PCM cache file (`RecordingPCMCacheFormat`, written by
 * [io.github.jiyimeta.sheetmusic.audio.recording.RecordingPcmDecoder]) placed against the reference recording's time,
 * with its strip's mix. Mirrors Apple's `RecordingTrack`; a recording strip sits on the same solo bus as the instrument
 * strips.
 */
data class RecordingTrack(
    /** Unique in a track list and stable across calls: a track whose id was already playing carries on from where it is. */
    val id: String,
    /**
     * The PCM cache file to play. Mapped by `setRecordingTracks`, and kept mapped by later calls for as long as the
     * track keeps its [id] and this path — a file rewritten in place under the same path is not re-read.
     */
    val pcmPath: String,
    /** Seconds into the reference recording's time at which this file starts. */
    val offsetSeconds: Double = 0.0,
    /** The track's own transposition, on top of the reader's (`setTranspose`). */
    val transposeSemitones: Int = 0,
    /** Linear gain in `0..1`, as an instrument strip's. */
    val volume: Float = 1f,
    val isMuted: Boolean = false,
    val isSoloed: Boolean = false,
)

/**
 * One stretch of the transport's own clock and the time it must last: transport seconds `[start, end)` take
 * [duration] seconds at 100 % rate. Mirrors Apple's `PlaybackTimeWarp.Span`; the stretch `(end − start) / duration`
 * must lie in `0.02..50`, and spans ascend without overlapping.
 */
data class PlaybackTimeWarpSpan(val start: Double, val end: Double, val duration: Double)

/**
 * A stretch of the reference recording, `[sourceStart, sourceEnd)` in reference seconds, that plays from warped output
 * second [outputStart] on. Mirrors Apple's `RecordingSegment`.
 */
data class RecordingSegment(val sourceStart: Double, val sourceEnd: Double, val outputStart: Double)

/**
 * What the transport and the recordings follow: [warpSpans] (empty = the notated tempo), the shared segment table, and
 * tables of a track's own keyed by track id, whose source seconds are that track's file seconds.
 */
data class PlaybackAlignment(
    val warpSpans: List<PlaybackTimeWarpSpan> = emptyList(),
    val segments: List<RecordingSegment> = emptyList(),
    val trackSegments: Map<String, List<RecordingSegment>> = emptyMap(),
) {
    /** Whether it sets anything: a span, a shared segment, or a segment of a track's own table. */
    val isEmpty: Boolean
        get() = warpSpans.isEmpty() && segments.isEmpty() && trackSegments.values.all { it.isEmpty() }
}
