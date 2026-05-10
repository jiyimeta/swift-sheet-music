import Foundation

/// A fermata symbol held above/below a chord or rest.
/// C++: `mu::engraving::Fermata`.
public struct Fermata: Sendable, Equatable {
    /// MuseScore `<subtype>` text (e.g. `fermataAbove`, `fermataBelow`,
    /// `fermataLongAbove`, …). Kept as a raw string because the full
    /// SMuFL-derived set is large and MuseScore 5.x extends it freely.
    public var subtype: String

    /// MIDI hold ratio. 1.0 = no stretch. MSCX `<timeStretch>` overrides
    /// the subtype default when present.
    /// C++: `mu::engraving::Fermata::timeStretch`.
    public var timeStretch: Double

    public init(subtype: String, timeStretch: Double? = nil) {
        self.subtype = subtype
        self.timeStretch = timeStretch ?? Self.defaultTimeStretch(for: subtype)
    }

    /// Subtype → default MIDI hold ratio. Mirrors MuseScore's
    /// per-symbol `Fermata::timeStretch` defaults.
    public static func defaultTimeStretch(for subtype: String) -> Double {
        switch subtype {
        case "fermataVeryShortAbove", "fermataVeryShortBelow",
             "fermataShortHenzeAbove", "fermataShortHenzeBelow":
            return 1.25
        case "fermataAbove", "fermataBelow",
             "fermataShortAbove", "fermataShortBelow":
            return 1.5
        case "fermataLongAbove", "fermataLongBelow",
             "fermataLongHenzeAbove", "fermataLongHenzeBelow":
            return 2.0
        case "fermataVeryLongAbove", "fermataVeryLongBelow":
            return 3.0
        default:
            return 1.5
        }
    }
}
