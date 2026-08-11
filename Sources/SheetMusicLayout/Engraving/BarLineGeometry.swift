#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Geometry constants and helpers for engraved barlines.
///
/// `LayoutElement.barLine(subtype:origin:)` carries the staff-middle Y
/// (the center of the four staff spaces) as the barline's origin. The
/// barline strokes extend ±2 sp from that origin, matching MuseScore's
/// convention.
public enum BarLineGeometry {
    /// Half-height of a barline in staff-spaces — i.e. the distance
    /// from the staff middle to the outermost staff line.
    public static let halfHeightSp: CGFloat = 2

    /// Thickness in staff-spaces for the thin component of any barline
    /// (single, double, repeat thin).
    public static let thinThicknessSp: CGFloat = 0.15

    /// Thickness in staff-spaces for the thick component of an end /
    /// final / repeat barline.
    public static let thickThicknessSp: CGFloat = 0.4

    /// Right edge of the staff lines for `system`, in
    /// system-local coordinates. Anchored to the rightmost stroke of
    /// the last measure's terminal barline so the staff passes through
    /// every component of a double / end / end-repeat pair, instead of
    /// running 0.5 sp past a plain barline through the trailing gutter
    /// baked into each measure's width.
    public static func staffLineEndX(for system: LayoutSystem) -> CGFloat {
        guard let bar = system.trailingBarLine else {
            return system.size.width
        }
        return bar.x + rightExtent(subtype: bar.subtype, sp: system.sp)
    }

    /// Distance from the barline `origin.x` to the right edge of the
    /// rightmost stroke this subtype paints. Used by the staff
    /// renderer to clip the five-line staff so it terminates flush
    /// with the system-end barline glyph (the staff should pass
    /// through every component of the barline pair, not stop at the
    /// thin half of an end / double / end-repeat).
    public static func rightExtent(
        subtype: String?, sp: CGFloat,
    ) -> CGFloat {
        switch subtype {
        case "end", "final":
            // Thick stroke at dx = +0.4 sp, width 0.4 sp → right edge.
            sp * 0.6
        case "end-repeat":
            // Thick stroke at dx = +0.3 sp, width 0.4 sp → right edge.
            sp * 0.5
        case "double":
            // Right thin stroke at dx = +0.3 sp, width 0.15 sp.
            sp * 0.375
        case "start-repeat":
            // Thin stroke at dx = +0.3 sp, width 0.15 sp. Repeat dots
            // sit further right but are not part of the staff line.
            sp * 0.375
        default:
            // Single thin stroke at dx = 0, width 0.15 sp.
            sp * 0.075
        }
    }
}
