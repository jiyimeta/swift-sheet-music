import Foundation

/// A silent duration. C++: `mu::engraving::Rest` (subset).
public struct Rest: Sendable, Equatable {
    public var duration: NoteDuration

    public init(duration: NoteDuration) {
        self.duration = duration
    }
}
