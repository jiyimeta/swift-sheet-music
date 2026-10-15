import SheetMusicCore
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

    /// Where MuseScore lays a fermata: its `<placement>`, else below for the second and fourth voice of a staff and
    /// above for the others (`Fermata::propertyDefault(PLACEMENT)`, `track() & 1`, `dom/fermata.cpp:190-193`). The
    /// subtype name does not move it.
    static func placedBelow(placement: Placement?, voiceIndex: Int) -> Bool {
        if let placement { return placement == .below }
        return !voiceIndex.isMultiple(of: 2)
    }

    /// The subtype MuseScore draws at that placement: its layout swaps a `…Below` name for its `…Above` twin above the
    /// staff and the reverse below it (`TLayout::layoutFermata`, `rendering/score/tlayout.cpp:1919-1929`), so a
    /// `fermataLongBelow` in the first voice with no `<placement>` draws the long fermata upright, over the staff.
    static func drawnSubtype(_ subtype: String, below: Bool) -> String {
        if below, subtype.hasSuffix("Above") { return String(subtype.dropLast(5)) + "Below" }
        if !below, subtype.hasSuffix("Below") { return String(subtype.dropLast(5)) + "Above" }
        return subtype
    }
}
