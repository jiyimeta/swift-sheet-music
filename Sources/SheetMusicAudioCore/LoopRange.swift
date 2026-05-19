// Sources/SheetMusicAudio/LoopRange.swift
import Foundation

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
}
