import SheetMusicAudioApple
import SheetMusicAudioCore
import SheetMusicAudioSwiftySynthCore
import SwiftySynth

// Recordings and the speed table on the SwiftySynth transport.
//
// The render-side state, the mix and the grouping are shared with Android's `HostedSynth`
// (`SheetMusicAudioSwiftySynthCore/Recording`): this backend keeps the state in `Shared.alignment`, under its lock, and
// hands its lock to `RecordingMixController` as the section a new track list or table is swapped in. See
// `PlaybackAlignmentState` for how the transport follows a warp.

extension SwiftySynthBackend {
    // MARK: Main actor

    /// `RecordingMixController`'s lock section: its body runs on `Shared.alignment` under `lock`.
    nonisolated func withAlignment(_ body: (inout PlaybackAlignmentState) -> Void) {
        lock.withLockUnchecked { shared in body(&shared.alignment) }
    }

    // MARK: SynthBackend

    public var canPlayRecordings: Bool {
        true
    }

    /// Replaces the recordings in one lock section, grouped by transposition and table with the tables of a track's
    /// own last set (`setPlaybackAlignment(warp:segments:trackSegments:)`). A track whose `id` was already playing
    /// keeps its playhead and its gain ramp, so a new gain neither fades nor jumps it: the render ramps to it over the
    /// fade. A group carries on the stretchers of the previous group that held most of its tracks
    /// (`RecordingGroupPlan`); when its transposition or its tracks changed, or a track's file or offset, the render
    /// restarts it, primed and retuned, and crossfades. A new table alone does not restart it: the render follows the
    /// table, jumping only where the group's target moves. A previous group nobody carries on is kept draining
    /// until its fade-out is over, and dropped by the first call after that. Stretchers a group now needs are made
    /// here, on the main actor. The previous arrays, stretchers and scratch are released after the lock, never on the
    /// render thread (`RecordingMixController.setRecordingTracks`).
    public func setRecordingTracks(_ tracks: [RecordingTrackRender]) {
        recordingMix.setRecordingTracks(tracks, withAlignment: withAlignment)
    }

    /// Swaps the speed table and the schedule together in one lock section: the next render call sees either the old
    /// pair or the new one, and the transport takes the new speed from its next block — no stop, seek or reload. The
    /// previous table and schedule are released after the lock, never on the render thread. Every track plays from
    /// `segments`: this is `setPlaybackAlignment(warp:segments:trackSegments:)` with no table of a track's own.
    public func setPlaybackAlignment(warp: PlaybackTimeWarp?, segments: [RecordingSegment]) {
        setPlaybackAlignment(warp: warp, segments: segments, trackSegments: [:])
    }

    /// As `setPlaybackAlignment(warp:segments:)`, with tables of a track's own: a track keyed in `trackSegments` plays
    /// its table at offset 0, every other track `segments` at its offset. Each group's table is laid out here, on the
    /// main actor, and the render reads it from the group without looking anything up.
    ///
    /// New tables that keep the grouping — a host dragging a track's placement pushes one per pointer event — are
    /// swapped into their groups in place, in the lock section that swaps the speed table and the schedule, and
    /// restart nothing: a group's stretcher jumps only where its target moves, as under a new shared table. A track's
    /// table decides its group, so tables that regroup the tracks group them again and hand the groups over in that
    /// one lock section instead; a group whose tracks changed restarts
    /// (`RecordingMixController.setPlaybackAlignment`).
    public func setPlaybackAlignment(
        warp: PlaybackTimeWarp?, segments: [RecordingSegment], trackSegments: [String: [RecordingSegment]],
    ) {
        recordingMix.setPlaybackAlignment(
            warp: warp, segments: segments, trackSegments: trackSegments, withAlignment: withAlignment,
        )
    }
}
