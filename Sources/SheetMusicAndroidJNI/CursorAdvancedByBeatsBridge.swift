import Foundation
import SheetMusicBridgeCore
import SheetMusicCore

/// JNI entry point for Kotlin `SheetMusicJNI.nativeCursorAdvancedByBeats(...)`. Advances `fromCursorBytes` by
/// `beats` quarter-note beats via the shared `Score.cursor(advancedByBeats:from:)` (deterministic notation math)
/// and returns the result as a `ScoreCursorCodec` payload. Returns `fromCursorBytes` unchanged when the handle is
/// unknown or the input cursor can't be decoded — identical failure mode to `nativeStepMeasureCursor`.
public func nativeCursorAdvancedByBeats(
    scoreHandle: Int64,
    fromCursorBytes: Data,
    beats: Double,
) -> Data {
    guard let score = scoreTable.value(for: scoreHandle),
          let from = try? ScoreCursorCodec.decode(fromCursorBytes)
    else { return fromCursorBytes }
    let target = score.cursor(advancedByBeats: beats, from: from)
    return ScoreCursorCodec.encode(target)
}
