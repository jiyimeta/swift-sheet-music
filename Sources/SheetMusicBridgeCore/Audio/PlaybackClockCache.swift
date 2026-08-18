import SheetMusicCore
import SheetMusicFoundation

/// One `PlaybackClock` per score handle.
///
/// Building one runs `PlaybackTimeline(score:)` and
/// `MidiRenderer.playbackUnroll(score:)`, both of which walk the whole score.
/// The browser's cursor poll asks for a frame once per animation frame, so
/// rebuilding per call would re-walk the score sixty times a second.
///
/// Only the wasm bridge uses it. The Android bridge keeps building its own on
/// every call, so this cannot change Android behaviour — deliberately, since
/// the Apple CI job does not exercise the Android bridge and a regression there
/// would not surface until after merge.
///
/// Thread safety: all reads and writes are serialized on `lock`, exactly like
/// `LayoutDocumentCache`. The `nonisolated(unsafe)` annotation suppresses the
/// Swift 6 global-mutable-state warning; `SerialLock` supplies the actual
/// safety.
package enum PlaybackClockCache {
    private static let lock = SerialLock(
        label: "SheetMusicBridgeCore.PlaybackClockCache",
    )
    private nonisolated(unsafe) static var storage: [Int64: PlaybackClock] = [:]

    package static func clock(for handle: Int64, score: Score) -> PlaybackClock {
        if let cached = lock.withLock({ storage[handle] }) { return cached }
        let built = PlaybackClock(score: score)
        lock.withLock { storage[handle] = built }
        return built
    }

    package static func release(_ handle: Int64) {
        lock.withLock { _ = storage.removeValue(forKey: handle) }
    }
}
