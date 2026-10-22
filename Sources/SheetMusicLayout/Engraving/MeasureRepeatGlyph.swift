#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicFoundation

/// SMuFL codepoint selection for the standard measure-repeat glyphs
/// (1, 2, or 4 bars). Unknown counts fall back to the 1-bar symbol,
/// matching MuseScore's behavior when the count is not one of the
/// engraved variants.
///
/// Also where the sign's ink sits around its layout origin, which every renderer centers the glyph on: the
/// glyph's own box, and for a 2- or 4-bar sign the number MuseScore stands above it (`TLayout::layoutMeasureRepeat`
/// sets `numberSym` to the bar count for both; a 1-bar sign's "1" is off by default, `oneMeasureRepeatShow1`).
public enum MeasureRepeatGlyph {
    public static func codepoint(forCount count: Int) -> UInt32 {
        switch count {
        case 2: return SMuFLCodepoint.repeat2Bars
        case 4: return SMuFLCodepoint.repeat4Bars
        default: return SMuFLCodepoint.repeat1Bar
        }
    }

    /// The time-signature digit drawn above a 2- or 4-bar sign, or `nil` for a sign that shows none.
    public static func numberCodepoint(forCount count: Int) -> UInt32? {
        switch count {
        case 2, 4: SMuFLCodepoint.timeSigDigit(count)
        default: nil
        }
    }

    /// Bravura's `glyphBBoxes` for `codepoint(forCount:)`, in staff spaces: `repeat1Bar` 2.128 × 2.116,
    /// `repeat2Bars` 3.048 wide, `repeat4Bars` 4.928 wide, all three the same height.
    static func inkSize(forCount count: Int) -> CGSize {
        switch count {
        case 2: CGSize(width: 3.048, height: 2.116)
        case 4: CGSize(width: 4.928, height: 2.116)
        default: CGSize(width: 2.128, height: 2.116)
        }
    }

    /// The sign's ink around its origin, which is the glyph's center.
    public static func inkRect(forCount count: Int, sp: CGFloat) -> CGRect {
        let size = inkSize(forCount: count)
        return CGRect(
            x: -size.width * sp / 2, y: -size.height * sp / 2, width: size.width * sp, height: size.height * sp,
        )
    }

    /// Where the number's center sits above the sign's: the digit's bottom half a space above the top staff line,
    /// MuseScore's `measureRepeatNumberPos` (-0.5 sp), on a sign centered on the middle line of a five-line staff —
    /// two spaces to the top line, half a space of gap, and half the digit's ~2 sp height.
    static let numberCenterAboveSign: CGFloat = 3.5

    /// The number's ink around the sign's origin (Bravura `timeSig2` / `timeSig4`, ~1.7 × 2 sp), or `nil` for a sign
    /// that shows none.
    public static func numberRect(forCount count: Int, sp: CGFloat) -> CGRect? {
        guard numberCodepoint(forCount: count) != nil else { return nil }
        let width = 1.72 * sp
        let height = 2.04 * sp
        return CGRect(x: -width / 2, y: -numberCenterAboveSign * sp - height / 2, width: width, height: height)
    }

    /// The sign's number center relative to its origin, for a renderer that centers the digit on a point.
    public static func numberCenter(forCount count: Int, sp: CGFloat) -> CGPoint? {
        numberRect(forCount: count, sp: sp).map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    /// Everything the sign draws around its origin — its glyph, and the number above a 2- or 4-bar one. What a click
    /// on it has to land in, as MuseScore hits an element by its shape.
    public static func drawnRect(forCount count: Int, sp: CGFloat) -> CGRect {
        let ink = inkRect(forCount: count, sp: sp)
        return numberRect(forCount: count, sp: sp).map(ink.union) ?? ink
    }
}
