#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicFoundation

/// Geometry constants and helpers for engraved barlines.
///
/// `LayoutElement.barLine(subtype:origin:halfHeight:)` carries both the
/// stroke's center Y and its half-height, so the vertical span is not
/// spelled out here: it depends on the staff's line count and is owned
/// by `StaffLineGeometry.barLineSpanY(sp:)`. A five-line staff still
/// gets ±2 sp; a one-line staff gets ±2 sp about its single line, and a
/// three-line staff ±1 sp. Renderers stroke `origin.y ± halfHeight`.
public enum BarLineGeometry {
    /// Thickness in staff-spaces for the thin component of any barline
    /// (single, double, repeat thin).
    public static let thinThicknessSp: CGFloat = 0.15

    /// Horizontal offset in staff-spaces of each stroke in a double
    /// barline, one negative and one positive from the element origin.
    public static let doubleStrokeDxSp: CGFloat = 0.3

    /// Horizontal offset of the thick stroke in an end / final barline.
    public static let endThickStrokeDxSp: CGFloat = 0.4

    /// Horizontal offset of the second stroke in a repeat barline.
    public static let repeatSecondStrokeDxSp: CGFloat = 0.3

    /// Horizontal offset of repeat dots from the barline origin.
    public static let repeatDotDxSp: CGFloat = 0.6

    /// Diameter of each repeat dot in staff-spaces. This keeps all three
    /// renderers aligned with the Apple circle they already drew.
    ///
    /// MuseScore instead draws `SymId::repeatDot` at its natural 0.4 sp
    /// ink size. Unifying on that SMuFL size is a follow-up because it
    /// would change every Apple repeat barline and the corpus pixel gate.
    public static let repeatDotDiameterSp: CGFloat = 0.3

    /// Bravura U+E044 `repeatDot` ink size at a 4 sp em. Measured through
    /// the real `FontMetrics.provider` with `sp = 5`,
    /// `pointSize = sp * 4`:
    /// `bbox=(0.0, -1.0, 2.0, 2.0) advance=2.0`, so its 2 pt ink
    /// diameter is 0.4 sp.
    public static let bravuraRepeatDotInkSp: CGFloat = 0.4

    /// Thickness in staff-spaces for the thick component of an end /
    /// final / repeat barline.
    public static let thickThicknessSp: CGFloat = 0.4

    /// Right edge of the staff lines for `system`, in system-local
    /// coordinates. A plain system end clips at the rightmost stroke of
    /// its terminal barline, excluding the measure's trailing gutter.
    /// When the last measure announces a courtesy key / time signature,
    /// the lines instead span the announcement band through that
    /// measure's right edge. MuseScore likewise lays staff lines out for
    /// the full measure width, which includes its announce segments.
    ///
    /// The announcement is detected positionally — a key / time
    /// signature drawn right of the terminal barline — rather than from
    /// the `TrailingCourtesy` table, so it is not exact: an explicit
    /// mid-measure barline suppresses the synthesized trailing one,
    /// which makes `trailingBarLine` report the mid-measure stroke and
    /// lets a later INLINE signature match too. That case runs the lines
    /// to the measure's right edge instead of stopping them mid-measure,
    /// which is the better of the two outcomes; being exact would mean
    /// carrying an announcement flag on `LayoutMeasure`, i.e. new model
    /// state on a type the rebuild paths reconstruct.
    ///
    /// C++: `TLayout::layoutStaffLines`
    /// (`src/engraving/rendering/score/tlayout.cpp:5184-5188`).
    public static func staffLineEndX(for system: LayoutSystem) -> CGFloat {
        guard let bar = system.trailingBarLine else {
            return system.size.width
        }
        let barEnd = bar.x + rightExtent(
            subtype: bar.subtype, sp: system.sp,
        )
        guard let last = system.measures.last else { return barEnd }
        let barX = bar.x - last.origin.x
        let announcesCourtesy = last.elements.contains { element in
            switch element {
            case let .keySignature(_, _, _, _, origin),
                 let .timeSignature(_, _, _, origin):
                origin.x > barX
            default:
                false
            }
        }
        guard announcesCourtesy else { return barEnd }
        return max(barEnd, last.origin.x + last.width)
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
            sp * (endThickStrokeDxSp + thickThicknessSp / 2)
        case "end-repeat":
            // Thick stroke at dx = +0.3 sp, width 0.4 sp → right edge.
            sp * (repeatSecondStrokeDxSp + thickThicknessSp / 2)
        case "double":
            // Right thin stroke at dx = +0.3 sp, width 0.15 sp.
            sp * (doubleStrokeDxSp + thinThicknessSp / 2)
        case "start-repeat":
            // Thin stroke at dx = +0.3 sp, width 0.15 sp. Repeat dots
            // sit further right but are not part of the staff line.
            sp * (repeatSecondStrokeDxSp + thinThicknessSp / 2)
        default:
            // Single thin stroke at dx = 0, width 0.15 sp.
            sp * thinThicknessSp / 2
        }
    }
}
