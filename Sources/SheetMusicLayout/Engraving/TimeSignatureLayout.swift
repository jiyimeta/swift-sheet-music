#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicFoundation

/// Spacing math for a stacked numerator-over-denominator time signature.
///
/// Renderers iterate `String(numerator)` / `String(denominator)`,
/// drawing each digit glyph at `digitAdvance * index + rowOffsetX`. The
/// helpers below produce the offsets that center multi-digit numerators
/// and denominators on a shared vertical axis (so "12/8" still looks
/// like a balanced fraction).
public enum TimeSignatureLayout {
    /// Bravura time-sig digits are ~1.3 sp wide at the glyph font size.
    /// A 1.4 sp advance keeps a "15" or "12" from overlapping while
    /// staying tight enough to read as a single number.
    public static func digitAdvance(sp: CGFloat) -> CGFloat {
        sp * 1.4
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
