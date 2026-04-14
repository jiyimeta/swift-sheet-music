import Foundation

/// Bar line marker. Display-only — does not affect MIDI output.
/// C++: `mu::engraving::BarLine`.
public struct BarLine: Sendable, Equatable {
    public var subtype: String?      // e.g. "end", "double", "start-repeat"

    public init(subtype: String? = nil) {
        self.subtype = subtype
    }
}
