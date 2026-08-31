#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicFoundation

/// Guitar-bend geometry: the two shapes MuseScore's
/// `GuitarBendLayout::layoutStandardStaff`
/// (`rendering/score/guitarbendlayout.cpp:82-95`) dispatches between on a
/// standard (non-tablature) staff.
///
/// * **Angular bend** — the shape for `bend`, `preBend` and
///   `graceNoteBend`: a two-segment polyline from the start anchor up
///   over a vertex and down to the end anchor. See `vertex(from:to:sp:up:)`.
/// * **Slight bend** — a short fixed-size cubic hook off the right side
///   of one notehead, with no notated destination. See
///   `slightBendEnd(sp:)` / `slightBendControl(sp:)`.
///
/// The whammy-bar types (`dive`, `preDive`, `dip`, `scoop`) route to
/// `GuitarDiveLayout` in MuseScore and are not modeled here.
public enum GuitarBendGeometry {
    /// Stroke thickness as a multiple of `sp`. MuseScore draws the bend
    /// with the same pen weight as a glissando line, so this mirrors
    /// `GlissandoGeometry.lineThicknessSp`.
    public static let lineThicknessSp: CGFloat = 0.15

    /// Minimum vertex height above the chord of the bend, in `sp`.
    /// C++: `vertexHeightMin` (`guitarbendlayout.cpp:184`).
    static let vertexHeightMinSp: CGFloat = 0.75
    /// Maximum vertex height, in `sp`.
    /// C++: `vertexHeightMax` (`guitarbendlayout.cpp:185`).
    static let vertexHeightMaxSp: CGFloat = 2.0

    /// Peak of an angular bend, in the SAME absolute frame as `from` and
    /// `to` (unlike MuseScore, which stores it relative to the segment
    /// position — carrying all three points in one frame is what lets the
    /// layout's translate pass shift them together).
    ///
    /// Ported from `GuitarBendLayout::layoutAngularBend`
    /// (`guitarbendlayout.cpp:184-198`):
    ///
    /// ```cpp
    /// double angle = -atan(relEndPoint.y() / relEndPoint.x());
    /// double vertexHeight = vertexHeightMin + 0.1 * (baseLength - minLength);
    /// vertexHeight = std::min(vertexHeight, vertexHeightMax);
    /// PointF vertex = 0.5 * relEndPoint;
    /// vertex += PointF(upSign * vertexHeight * sin(angle),
    ///                  upSign * vertexHeight * cos(angle));
    /// ```
    ///
    /// with `minLength = spatium` and `upSign = up ? -1 : 1` (y grows
    /// downward, so an upward bend displaces by a negative y).
    ///
    /// Two guards are ours, not MuseScore's:
    /// * the height is also **floored** at `vertexHeightMinSp`. MuseScore
    ///   relies on `adjustX` having spread the anchors by at least one
    ///   spatium before this point; without that pass a short run would
    ///   flatten (or invert) the vertex.
    /// * a non-positive run short-circuits `angle` to 0 rather than
    ///   evaluating `atan(0 / 0)`, which is `NaN`. A pre-bend pairs a note
    ///   with itself, so `to == from` is a case that really occurs; the
    ///   result is a purely vertical tick of `vertexHeightMinSp`.
    ///
    /// MuseScore then runs `avoidBadStaffLineIntersection` over the result
    /// (`guitarbendlayout.cpp:200`) to nudge a vertex off a staff line it
    /// would otherwise land exactly on. That is deliberately not modeled in
    /// v1, so a vertex may coincide with a staff line.
    ///
    /// - Parameters:
    ///   - from: Start anchor, absolute.
    ///   - to: End anchor, absolute.
    ///   - sp: One staff space, in points.
    ///   - up: `true` when the bend rises (end pitch at or above start).
    public static func vertex(
        from: CGPoint, to: CGPoint, sp: CGFloat, up: Bool,
    ) -> CGPoint {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let angle: CGFloat = dx > 0 ? -atan(dy / dx) : 0
        let upSign: CGFloat = up ? -1 : 1
        let height = min(
            max(
                sp * vertexHeightMinSp + 0.1 * (dx - sp),
                sp * vertexHeightMinSp,
            ),
            sp * vertexHeightMaxSp,
        )
        return CGPoint(
            x: from.x + dx / 2 + upSign * height * sin(angle),
            y: from.y + dy / 2 + upSign * height * cos(angle),
        )
    }

    /// End point of a slight bend's cubic hook, RELATIVE to the start
    /// anchor: `PointF(1.25 * spatium, -1.0 * spatium)`.
    /// C++: `GuitarBendLayout::layoutSlightBend`
    /// (`guitarbendlayout.cpp:370`).
    public static func slightBendEnd(sp: CGFloat) -> CGPoint {
        CGPoint(x: sp * 1.25, y: -sp)
    }

    /// Control point of a slight bend's cubic hook, RELATIVE to the start
    /// anchor: `PointF(endPos.x(), 0.0)` — level with the anchor, so the
    /// hook leaves the notehead horizontally before turning up.
    /// C++: `GuitarBendLayout::layoutSlightBend`
    /// (`guitarbendlayout.cpp:371`).
    public static func slightBendControl(sp: CGFloat) -> CGPoint {
        CGPoint(x: slightBendEnd(sp: sp).x, y: 0)
    }

    /// Start anchor of a slight bend, RELATIVE to the notehead origin:
    /// `startNotePos + PointF(startNote->width() + 0.25 * spatium,
    /// -0.25 * spatium)`. C++: `guitarbendlayout.cpp:369`.
    ///
    /// MuseScore's `startNotePos` is the notehead's top-left corner; our
    /// note origins are notehead CENTRES, so the full width becomes half
    /// a width past the centre.
    static func slightBendStartOffset(sp: CGFloat) -> CGPoint {
        CGPoint(x: sp * (noteheadWidthSp / 2 + 0.25), y: sp * -0.25)
    }

    /// Bravura `noteheadBlack` advance width, in `sp`. Same constant the
    /// skyline's `noteheadRect` uses.
    static let noteheadWidthSp: CGFloat = 1.18
    /// Bravura `noteheadBlack` height, in `sp`.
    static let noteheadHeightSp: CGFloat = 1.0

    /// Anchor offset from a notehead CENTRE for an angular bend, mirroring
    /// `layoutAngularBend`'s `xOff` / `yOff` (`guitarbendlayout.cpp:138-162`):
    ///
    /// ```cpp
    /// double xOff = (isInside ? 1 : 0.5) * startNote->width()
    ///             + horizontalIndent * startNote->mag();   // begin
    /// double xOff = (isInside ? 0 : 0.5) * endNote->width()
    ///             - horizontalIndent * endNote->mag();     // end
    /// double yOff = upSign * verticalPadding * mag;
    /// if (!isInside) { yOff += upSign * 0.5 * note->height(); }
    /// ```
    ///
    /// with `horizontalIndent = verticalPadding = 0.2 * spatium`.
    ///
    /// **The two axes need different frame conversions.** MuseScore's
    /// `startNotePos` / `endNotePos` are the notehead glyph's origin: its
    /// LEFT edge horizontally, but its vertical CENTRE (a notehead is drawn
    /// centred on its staff line). Our note origins are the notehead centre
    /// on BOTH axes, so:
    ///
    /// * horizontally the `0.5 * width` term is exactly the left-edge →
    ///   centre conversion and cancels, leaving `±0.2 sp`. (An earlier
    ///   revision kept both terms and pushed each anchor a further half
    ///   notehead outward — see `slightBendStartOffset`, which documents
    ///   the same conversion for its `width` term.)
    /// * vertically nothing cancels, so the full
    ///   `0.2 sp + 0.5 * noteheadHeight` carries over.
    ///
    /// Two things MuseScore does around these offsets are deliberately NOT
    /// modeled in v1:
    ///
    /// * `isInside` (a bend between two noteheads of the same chord) —
    ///   every bend here takes the `!isInside` branch.
    /// * `avoidBadStaffLineIntersection` (`guitarbendlayout.cpp:171-172`
    ///   for the anchors, `:200` for the vertex), which nudges a point off
    ///   a staff line it would otherwise sit exactly on.
    ///
    /// - Parameters:
    ///   - start: `true` for the begin anchor (which sits to the RIGHT of
    ///     its notehead centre), `false` for the end anchor (to the LEFT).
    static func angularAnchorOffset(
        sp: CGFloat, up: Bool, start: Bool,
    ) -> CGPoint {
        let upSign: CGFloat = up ? -1 : 1
        let indent = sp * 0.2
        return CGPoint(
            x: start ? indent : -indent,
            y: upSign * sp * (0.2 + noteheadHeightSp / 2),
        )
    }
}
