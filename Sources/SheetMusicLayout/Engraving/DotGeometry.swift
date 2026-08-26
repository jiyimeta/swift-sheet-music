#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicFoundation

/// Augmentation dot placement after a notehead or rest.
///
/// Standard engraving: small filled circle ~1 sp right of the
/// notehead's anchor, further dots spaced 0.6 sp apart. When the
/// anchor sits ON a staff line (even staff step) the first dot
/// shifts half a space UP into the adjacent line-gap so it doesn't
/// overlap the staff line; when the anchor is already in a space
/// (odd step) the dot stays put.
public enum DotGeometry {
    /// Dot disc radius in staff-spaces.
    public static let radiusSp: CGFloat = 0.22

    /// Distance from the notehead anchor X to the FIRST dot's center X.
    public static let firstOffsetSp: CGFloat = 1.15

    /// Spacing between consecutive dot centers.
    public static let spacingSp: CGFloat = 0.6

    /// Dot center positions for `count` augmentation dots after a
    /// notehead/rest at `anchor`. Caller draws each as a filled
    /// circle of radius `radiusSp · sp`.
    public static func centers(
        after anchor: CGPoint,
        count: Int,
        onStaffLine: Bool,
        sp: CGFloat,
    ) -> [CGPoint] {
        guard count > 0 else { return [] }
        let firstOffset = firstOffsetSp * sp
        let spacing = spacingSp * sp
        let y = onStaffLine ? anchor.y - sp / 2 : anchor.y
        return (0 ..< count).map { i in
            CGPoint(
                x: anchor.x + firstOffset + CGFloat(i) * spacing,
                y: y,
            )
        }
    }
}
