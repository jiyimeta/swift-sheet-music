import Foundation
import SheetMusicAudioCore
import SheetMusicCore

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeCountIn(...)` call site. Returns the count-in ("pre-roll") click schedule for
/// playback starting at `fromCursorBytes`, as a `CountInCodec` payload whose offsets are in seconds.
///
/// The schedule itself comes from the shared `CountInBeats` — the same code the Apple engine's pre-roll
/// sequence is assembled from, so both platforms prepend the same measure, honour the same anacrusis
/// shim, and count the same mid-measure lead-in.
///
/// An unknown handle, an undecodable cursor, or a score `CountInBeats` cannot schedule (no measures, no
/// division, no tempo) all encode an EMPTY schedule rather than raw `Data()`, so the Kotlin decoder can
/// run unconditionally and simply reads "no count-in — start now".
public func nativeCountIn(scoreHandle: Int64, fromCursorBytes: Data) -> Data {
    let empty = CountInCodec.encode(CountInWire(totalSeconds: 0, beats: []))
    guard let score = scoreTable.value(for: scoreHandle) else { return empty }
    // A missing / undecodable cursor means "from the top", which is what CountInBeats does with nil.
    let cursor = try? ScoreCursorCodec.decode(fromCursorBytes)
    guard let result = CountInBeats.compute(score: score, startCursor: cursor) else { return empty }
    return CountInCodec.encode(CountInCodec.wire(from: result, division: score.division))
}
