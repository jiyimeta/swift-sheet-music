import Foundation

/// Measure-repeat marker (`<MeasureRepeat>` in mscx) — replays the previous N measure(s).
/// C++: `mu::engraving::MeasureRepeat`.
public struct MeasureRepeat: Sendable, Equatable {
    public var numMeasures: Int // 1, 2, or 4 typically
    public var duration: NoteDuration // total time the marker spans (usually one measure)

    public init(numMeasures: Int, duration: NoteDuration) {
        self.numMeasures = numMeasures
        self.duration = duration
    }
}
