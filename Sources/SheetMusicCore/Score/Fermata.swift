import Foundation

/// A fermata symbol held above/below a chord or rest.
/// C++: `mu::engraving::Fermata`.
public struct Fermata: Sendable, Equatable {
    /// MuseScore `<subtype>` text (e.g. `fermataAbove`, `fermataBelow`,
    /// `fermataLongAbove`, …). Kept as a raw string because the full
    /// SMuFL-derived set is large and MuseScore 5.x extends it freely.
    public var subtype: String

    public init(subtype: String) {
        self.subtype = subtype
    }
}
