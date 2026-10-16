#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicFoundation

/// Geometry constants and helpers for engraved barlines.
///
/// `LayoutElement.barLine` carries both the
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
        guard let last = system.measures.last, let bar = trailingBarLine(of: last) else {
            return system.size.width
        }
        let barEnd = strokeEndX(of: bar, sp: system.sp)
        let barX = bar.x - last.origin.x
        let announcesCourtesy = last.elements.contains { element in
            switch element {
            case let .keySignature(_, _, _, _, origin, _),
                 let .timeSignature(_, _, _, origin, _):
                origin.x > barX
            default:
                false
            }
        }
        guard announcesCourtesy else { return barEnd }
        return max(barEnd, last.origin.x + last.width)
    }

    /// The system-local x runs one staff's lines are drawn over, left to right: from `startX` (where the staff starts)
    /// to `staffEndX`, broken at each of `system.staffLineGaps` — an `<HBox>`'s room, where MuseScore draws no staff
    /// because staff lines belong to measures. A system without gaps gives the one run every renderer drew before.
    /// The one place the split rule lives, so the Apple renderers, the draw program and the staff bands break the
    /// lines at the same x.
    ///
    /// `staffEndX` is `staffLineEndX(for: system)`. The caller works it out once per system and passes it for every
    /// staff, as the renderers did before the split: it scans the last measure's elements, so per staff it would cost
    /// a system of N staves N scans.
    ///
    /// Without a gap inside the staff this is exactly `[startX ..< max(startX, staffEndX)]`, so a score without an
    /// HBox draws the lines it always drew, byte for byte.
    package static func staffLineSegments(
        for system: LayoutSystem, startX: CGFloat, staffEndX: CGFloat,
    ) -> [Range<CGFloat>] {
        let endX = max(startX, staffEndX)
        let gaps = system.staffLineGaps.filter { $0.upperBound > startX && $0.lowerBound < endX }
        guard !gaps.isEmpty else { return [startX ..< endX] }
        var runs: [Range<CGFloat>] = []
        var runStart = startX
        for gap in gaps {
            if gap.lowerBound > runStart {
                runs.append(runStart ..< gap.lowerBound)
            }
            runStart = max(runStart, gap.upperBound)
        }
        if runStart < endX {
            runs.append(runStart ..< endX)
        }
        return runs
    }

    /// Where the rightmost barline stroke `measure` draws ends, in system-local x: that barline's `origin.x` plus its
    /// subtype's `rightExtent`. Staff lines stop there at a system's end (`staffLineEndX(for:)`) and before an
    /// `<HBox>`'s room (`LayoutSystem.staffLineGaps`), as MuseScore's stop at the barline. `nil` when the measure draws
    /// no barline.
    static func barLineEndX(of measure: LayoutMeasure, sp: CGFloat) -> CGFloat? {
        trailingBarLine(of: measure).map { strokeEndX(of: $0, sp: sp) }
    }

    /// Subtype and system-local x of the rightmost barline `measure` draws, `nil` when it draws none. The first of two
    /// at the same x wins. Backs `LayoutSystem.trailingBarLine`.
    static func trailingBarLine(of measure: LayoutMeasure) -> (subtype: String?, x: CGFloat)? {
        var rightmostX: CGFloat = -.infinity
        var rightmostSubtype: String?
        for el in measure.elements {
            if case let .barLine(s, p, _, _, _) = el, p.x > rightmostX {
                rightmostX = p.x
                rightmostSubtype = s
            }
        }
        guard rightmostX.isFinite else { return nil }
        return (rightmostSubtype, measure.origin.x + rightmostX)
    }

    private static func strokeEndX(of bar: (subtype: String?, x: CGFloat), sp: CGFloat) -> CGFloat {
        bar.x + rightExtent(subtype: bar.subtype, sp: sp)
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

    /// Distance from the barline `origin.x` to the left edge of the leftmost ink this subtype paints — what a trailing
    /// grace note before it keeps clear of.
    static func leftExtent(subtype: String?, sp: CGFloat) -> CGFloat {
        switch subtype {
        case "end-repeat":
            // Repeat dots centered at dx = -0.6 sp.
            sp * (repeatDotDxSp + repeatDotDiameterSp / 2)
        case "double":
            // Left thin stroke at dx = -0.3 sp, width 0.15 sp.
            sp * (doubleStrokeDxSp + thinThicknessSp / 2)
        default:
            // A thin stroke at dx = 0, alone or with a thick one or repeat dots to its right.
            sp * thinThicknessSp / 2
        }
    }
}
