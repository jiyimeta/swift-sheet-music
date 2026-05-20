import Foundation

/// SMuFL codepoint selection for fermatas.
///
/// MuseScore's raw subtype strings ("fermataAbove", "fermataBelow",
/// "fermataLongAbove", "fermataShortBelow", …) all share the same
/// prefix family for above/below. We pick the variant by prefix;
/// unknown subtypes fall back to the standard above-fermata glyph.
public enum FermataGlyph {
    public static func codepoint(forSubtype subtype: String) -> UInt32 {
        if subtype.hasPrefix("fermataBelow") {
            return SMuFLCodepoint.fermataBelow
        }
        return SMuFLCodepoint.fermataAbove
    }
}
