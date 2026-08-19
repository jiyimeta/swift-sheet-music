import Foundation
import SheetMusicAudioCore
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicMIDI

// Host-testable bridge helpers + swift-java JNI entry point for resolving
// an `AudioExportRange` (encoded by Kotlin) into a half-open
// `[startTick, endTick)` range against a score's `PlaybackTimeline`.

extension AudioMidiBridge {
    /// Resolve the encoded range payload against the score's timeline.
    ///
    /// Returns `(-1, -1)` on any failure (unknown tag, version mismatch,
    /// unresolvable cursor, empty range). `.currentLoop` falls back to
    /// `.full` semantics here because the engine's loop state lives on
    /// the Kotlin side; the host resolves `.currentLoop` itself before
    /// calling into JNI.
    static func resolveExportTickRange(
        score: Score, rangePayload: Data,
    ) -> (start: Int64, end: Int64) {
        do {
            let range = try AudioExportRangeCodec.decode(rangePayload)
            let timeline = PlaybackTimeline(score: score)
            let resolved = try range.resolveTickRange(timeline: timeline, loop: nil)
            return (Int64(resolved.startTick), Int64(resolved.endTick))
        } catch {
            return (-1, -1)
        }
    }
}

// MARK: - swift-java entry points

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeResolveExportTickRange(...)` call site.
/// Returns `[startTick, endTick]`, or `[-1, -1]` on any failure
/// (unknown score handle, empty / undecodable payload, version
/// mismatch, unresolvable cursor, empty range).
public func nativeResolveExportTickRange(scoreHandle: Int64, rangeBytes: Data) -> [Int64] {
    guard let score = scoreTable.value(for: scoreHandle) else { return [-1, -1] }
    guard !rangeBytes.isEmpty else { return [-1, -1] }
    let (start, end) = AudioMidiBridge.resolveExportTickRange(
        score: score, rangePayload: rangeBytes,
    )
    return [start, end]
}
