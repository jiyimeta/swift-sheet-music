#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Geometry constants and segment layout for a tuplet bracket.
///
/// MuseScore's `src/engraving/rendering/score/tupletlayout.cpp` paints
/// a non-beamed tuplet as `|‾‾‾ N ‾‾‾|`: two short vertical hooks at
/// the endpoints, two horizontal segments interrupted by an italic
/// label in the middle. The constants below mirror that convention.
public enum TupletBracketGeometry {
    /// Hook (the short vertical descent at each end of the bracket)
    /// height in staff-spaces.
    public static let hookHeightSp: CGFloat = 0.8

    /// Stroke thickness in staff-spaces for both hooks and horizontal
    /// segments.
    public static let lineThicknessSp: CGFloat = 0.12

    /// Label font size in staff-spaces. MuseScore uses ~2 sp for the
    /// digit at default styling.
    public static let labelFontSizeSp: CGFloat = 2

    /// Half the gap reserved for the label within the bracket's
    /// horizontal run, in staff-spaces. Wider than the visible glyph
    /// width to keep the bracket from touching the digit.
    ///
    /// Equivalent to MuseScore's `fontSize * 0.4` ≈ `2 sp * 0.4` =
    /// `0.8 sp`.
    public static let labelHalfWidthSp: CGFloat = 0.8

    public struct Segments: Sendable, Equatable {
        public let leftHookFrom: CGPoint
        public let leftHookTo: CGPoint
        public let rightHookFrom: CGPoint
        public let rightHookTo: CGPoint
        public let leftSegFrom: CGPoint
        public let leftSegTo: CGPoint
        public let rightSegFrom: CGPoint
        public let rightSegTo: CGPoint
        public let labelCenter: CGPoint
    }

    /// Compute the four bracket segments + the label center for a
    /// tuplet whose horizontal span is `from → to`. The hook descent
    /// flips sign based on whether the bracket is drawn above or below
    /// the staff.
    public static func segments(
        from: CGPoint, to: CGPoint,
        isAbove: Bool,
        sp: CGFloat,
    ) -> Segments {
        let labelX = (from.x + to.x) / 2
        let labelY = (from.y + to.y) / 2
        let hookSign: CGFloat = isAbove ? 1 : -1
        let hookDy = hookHeightSp * sp * hookSign
        let labelHalfWidth = labelHalfWidthSp * sp
        return Segments(
            leftHookFrom: CGPoint(x: from.x, y: from.y + hookDy),
            leftHookTo: from,
            rightHookFrom: CGPoint(x: to.x, y: to.y + hookDy),
            rightHookTo: to,
            leftSegFrom: from,
            leftSegTo: CGPoint(
                x: labelX - labelHalfWidth,
                y: interpY(
                    from: from, to: to,
                    x: labelX - labelHalfWidth,
                ),
            ),
            rightSegFrom: CGPoint(
                x: labelX + labelHalfWidth,
                y: interpY(
                    from: from, to: to,
                    x: labelX + labelHalfWidth,
                ),
            ),
            rightSegTo: to,
            labelCenter: CGPoint(x: labelX, y: labelY),
        )
    }

    private static func interpY(
        from: CGPoint, to: CGPoint, x: CGFloat,
    ) -> CGFloat {
        let span = to.x - from.x
        guard abs(span) > 0.01 else { return from.y }
        let t = (x - from.x) / span
        return from.y + (to.y - from.y) * t
    }
}
