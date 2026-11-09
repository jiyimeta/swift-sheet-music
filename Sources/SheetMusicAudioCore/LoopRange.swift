// Sources/SheetMusicAudio/LoopRange.swift
import SheetMusicFoundation

/// Half-open tick range `[startTick, endTick)` the engine should
/// loop while playing. Tick-based rather than cursor-based because
/// `setLoop(from:throughEndOf:)` wraps at an item's offset, which
/// rarely coincides with a `ScoreCursor` column. Hosts that want a
/// cursor for the boundaries can resolve via
/// `PlaybackTimeline.frame(atTick:)`.
public struct LoopRange: Sendable, Equatable {
    public let startTick: Int
    public let endTick: Int

    public init(startTick: Int, endTick: Int) {
        self.startTick = startTick
        self.endTick = endTick
    }

    /// Whether `tick` is inside the half-open range. Requires `startTick < endTick`; an empty or reversed range
    /// contains nothing.
    public func contains(_ tick: Int) -> Bool {
        tick >= startTick && tick < endTick
    }

    /// Where a seek to the notated `tick` lands with this loop set — the one rule the Apple and the Windows engine
    /// both seek by. Playing, inside the loop: its start for a `tick` outside it, so playback never leaves the
    /// section. Stopped or paused, at `tick` itself: the user is parking the cursor, typically past the section to set
    /// a new B there, and snapping it back to A undid the tap (user report, 2026-11-02). The loop takes over when
    /// playback starts: each engine's `play` begins a start outside the loop at the loop's start. Requires
    /// `startTick < endTick`; with an empty or reversed range every playing seek lands on `startTick`.
    public func seekTick(_ tick: Int, whilePlaying isPlaying: Bool) -> Int {
        guard isPlaying, !contains(tick) else { return tick }
        return startTick
    }
}
