import SheetMusicFoundation

/// SMuFL codepoint selection for fermatas.
///
/// MuseScore writes fourteen fermata subtypes (`fermataAbove`, `fermataBelow`, `fermataShortAbove`,
/// `fermataLongHenzeBelow`, …), each with its own SMuFL glyph; `SMuFLCodepoint.byName` is the single
/// source of the code points. Unknown subtypes fall back to the standard above-fermata glyph.
public enum FermataGlyph {
    private static let fermataNames: Set = [
        "fermataAbove", "fermataBelow",
        "fermataVeryShortAbove", "fermataVeryShortBelow",
        "fermataShortAbove", "fermataShortBelow",
        "fermataLongAbove", "fermataLongBelow",
        "fermataVeryLongAbove", "fermataVeryLongBelow",
        "fermataLongHenzeAbove", "fermataLongHenzeBelow",
        "fermataShortHenzeAbove", "fermataShortHenzeBelow",
    ]

    public static func codepoint(forSubtype subtype: String) -> UInt32 {
        guard fermataNames.contains(subtype), let codepoint = SMuFLCodepoint.byName(subtype) else {
            return SMuFLCodepoint.fermataAbove
        }
        return codepoint
    }

    /// Whether a subtype hangs below the staff: its name ends in `Below`.
    public static func isBelow(_ subtype: String) -> Bool {
        subtype.hasSuffix("Below")
    }
}
