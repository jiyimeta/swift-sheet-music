#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

/// Spacing math for a stacked numerator-over-denominator time signature.
///
/// Renderers iterate `String(numerator)` / `String(denominator)`,
/// drawing each digit glyph at `digitAdvance * index + rowOffsetX`. The
/// helpers below produce the offsets that center multi-digit numerators
/// and denominators on a shared vertical axis (so "12/8" still looks
/// like a balanced fraction).
///
/// A signature whose `TimeSignatureSymbol` is not `.numeric` is one
/// glyph, not two rows: `symbolCodepoint(_:)` names it and it is drawn
/// centered on the staff middle, which is what MuseScore does for all
/// four symbols (`TLayout::layoutTimeSig`, where every non-`NORMAL`
/// branch sets `pz` to the middle and clears the denominator row).
public enum TimeSignatureLayout {
    /// The single glyph this symbol is drawn as, or `nil` for
    /// `.numeric`, which is drawn as a stack of digits instead.
    public static func symbolCodepoint(
        _ symbol: TimeSignatureSymbol,
    ) -> UInt32? {
        switch symbol {
        case .numeric: nil
        case .common: SMuFLCodepoint.timeSigCommon
        case .cutCommon: SMuFLCodepoint.timeSigCutCommon
        case .cutBach: SMuFLCodepoint.timeSigCut2
        case .cutTriple: SMuFLCodepoint.timeSigCut3
        }
    }

    /// Bravura time-sig digits are ~1.3 sp wide at the glyph font size.
    /// A 1.4 sp advance keeps a "15" or "12" from overlapping while
    /// staying tight enough to read as a single number.
    public static func digitAdvance(sp: CGFloat) -> CGFloat {
        sp * 1.4
    }

    /// Ink width of one time-signature digit — the WIDEST of the ten, so
    /// a reservation made from it fits whichever digits land there.
    ///
    /// Bravura's `glyphBBoxes` (`fonts/bravura/bravura_metadata.json`),
    /// in staff spaces (SMuFL puts one em at 4 sp, and
    /// `StaffMetrics.glyphFontSize` is exactly `sp * 4`): `timeSig0` and
    /// `timeSig4` are the widest at 1.72; `timeSig1` the narrowest at
    /// 1.176.
    ///
    /// This is WIDER than `digitAdvance`, which is why the doc above
    /// calls 1.4 sp "tight": adjacent digits in a "12" share a sliver of
    /// side bearing. That is a deliberate look, but it means a column
    /// sized as `count * digitAdvance` does not contain the row's ink.
    static func digitWidth(sp: CGFloat) -> CGFloat {
        sp * 1.72
    }

    /// Ink width of one time-signature SYMBOL — the widest of the four,
    /// so a reservation made from it fits whichever symbol lands there.
    ///
    /// Bravura's `glyphBBoxes` in staff spaces: `timeSigCommon` 1.676,
    /// `timeSigCutCommon` 1.672, `timeSigCut2` 1.624, `timeSigCut3`
    /// 1.524. All four are just under `digitWidth`, so a symbol never
    /// needs more room than the numbers it replaces.
    static func symbolWidth(sp: CGFloat) -> CGFloat {
        sp * 1.68
    }

    /// Horizontal ink the signature occupies.
    ///
    /// A symbol is one glyph drawn centered on the origin, so its ink is
    /// just `symbolWidth`. Digits are drawn CENTERED on their stride
    /// (`TimeSignatureRenderer.drawRow`), so the wider of the two rows
    /// spans `(count - 1)` strides plus one whole digit.
    static func inkWidth(
        numerator: Int, denominator: Int,
        symbol: TimeSignatureSymbol, sp: CGFloat,
    ) -> CGFloat {
        guard symbol == .numeric else { return symbolWidth(sp: sp) }
        let count = max(digitCount(numerator), digitCount(denominator))
        guard count > 0 else { return 0 }
        return CGFloat(count - 1) * digitAdvance(sp: sp)
            + digitWidth(sp: sp)
    }

    /// Vertical offset of the numerator row baseline anchor, relative
    /// to the staff middle. The staff has four spaces; the numerator
    /// sits one staff-space above the middle.
    public static func numeratorDy(sp: CGFloat) -> CGFloat {
        -sp
    }

    /// Vertical offset of the denominator row, one staff-space below
    /// the middle.
    public static func denominatorDy(sp: CGFloat) -> CGFloat {
        sp
    }

    /// Vertical offset of a SYMBOL, which sits on the staff middle —
    /// the axis the two digit rows straddle. Spelled out rather than
    /// left as a bare `0` so the three renderers agree by name.
    public static func symbolDy(sp _: CGFloat) -> CGFloat {
        0
    }

    /// `(numeratorOffsetX, denominatorOffsetX, maxWidth)` such that the
    /// two rows are centered on the same vertical axis at the row
    /// origin's `x`.
    public static func rowOffsets(
        numerator: Int, denominator: Int, sp: CGFloat,
    ) -> (
        numeratorOffsetX: CGFloat,
        denominatorOffsetX: CGFloat,
        maxWidth: CGFloat,
    ) {
        let advance = digitAdvance(sp: sp)
        let numCount = digitCount(numerator)
        let denCount = digitCount(denominator)
        let numWidth = CGFloat(numCount) * advance
        let denWidth = CGFloat(denCount) * advance
        let maxWidth = max(numWidth, denWidth)
        return (
            numeratorOffsetX: (maxWidth - numWidth) / 2,
            denominatorOffsetX: (maxWidth - denWidth) / 2,
            maxWidth: maxWidth,
        )
    }

    private static func digitCount(_ value: Int) -> Int {
        String(value).count
    }
}
