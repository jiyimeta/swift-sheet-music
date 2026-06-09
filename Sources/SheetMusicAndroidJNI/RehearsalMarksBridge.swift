import Foundation
import SheetMusicCore

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeRehearsalMarks(...)` call site. Returns the score's
/// rehearsal marks — each carrying its text, its 0...1 notated-time fraction, and
/// the `ScoreCursor` to seek to — as a `RehearsalMarkCodec` list payload.
///
/// An unknown handle encodes an EMPTY list (not raw `Data()`), so the `i32 count`
/// header is always present and the Kotlin decoder can run unconditionally.
public func nativeRehearsalMarks(scoreHandle: Int64) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return RehearsalMarkCodec.encode([]) }
    return RehearsalMarkCodec.encode(score.rehearsalMarks())
}
