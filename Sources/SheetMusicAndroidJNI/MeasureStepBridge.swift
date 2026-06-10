import Foundation
import SheetMusicCore

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeStepMeasureCursor(...)` call site. Steps the engine
/// cursor by one measure in `direction` (`0 = backward`, `1 = forward`), using the
/// shared `Score.cursorSteppingMeasure(from:direction:)` so iOS and Android agree
/// on the measure-step semantics (forward clamps at the last measure; backward
/// restarts the current measure when past its first beat, else jumps to the
/// previous measure's downbeat, clamping at measure 0).
///
/// `fromCursorBytes` is a `ScoreCursorCodec` payload; the result is the same wire
/// format. Returns `fromCursorBytes` unchanged when the handle is unknown or the
/// input cursor fails to decode, so the caller never advances on a bad input.
public func nativeStepMeasureCursor(scoreHandle: Int64, fromCursorBytes: Data, direction: Int32) -> Data {
    guard let score = scoreTable.value(for: scoreHandle),
          let from = try? ScoreCursorCodec.decode(fromCursorBytes)
    else { return fromCursorBytes }
    let dir: MeasureStepDirection = direction == 0 ? .backward : .forward
    let target = score.cursorSteppingMeasure(from: from, direction: dir)
    return ScoreCursorCodec.encode(target)
}
