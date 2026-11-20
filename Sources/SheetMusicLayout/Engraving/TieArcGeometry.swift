#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicFoundation

/// Cubic-Bezier anchors for a symmetric tie or slur arc.
///
/// Renderers either feed these to `Path.curve(to:control1:control2:)`
/// directly (SwiftUI / PDF) or tessellate them to a line-segment
/// polyline (Android — the wire format has no curve opcode).
///
/// The geometry mirrors MuseScore's `SlurTieLayout::computeBezier`: the
/// arc's two interior control points sit at ≈ 20% and 80% of the span,
/// both lifted by `heightSp · sp` from the baseline on the chosen side.
public enum TieArcGeometry {
    /// Head clearance (in staff-spaces) — distance the arc endpoints
    /// hover off the notehead anchor so the arc doesn't dive into the
    /// glyph ink.
    public static let defaultHeadClearanceSp: CGFloat = 0.6

    /// Shoulder height (staff-spaces) scaled by the square root of the
    /// tie's length, so long ties flatten instead of ballooning. From
    /// MuseScore's `styledef`: `tieMinShoulderHeight = 0.3 sp`,
    /// `tieMaxShoulderHeight = 2.0 sp`. Shared so the Apple `TieRenderer`
    /// and the Android `LayoutBridge` use one curve instead of Android's
    /// old fixed 1 sp.
    public static func shoulderHeightSp(tieLengthSp: CGFloat) -> CGFloat {
        let clamped = max(tieLengthSp, 1.0)
        let raw = 0.3 + 0.3 * (clamped - 1).squareRoot()
        return min(max(raw, 0.3), 2.0)
    }

    public struct ControlPoints: Equatable, Sendable {
        public let p0: CGPoint
        public let p1: CGPoint
        public let p2: CGPoint
        public let p3: CGPoint

        public init(p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint) {
            self.p0 = p0
            self.p1 = p1
            self.p2 = p2
            self.p3 = p3
        }
    }

    /// Compute the four cubic-Bezier anchors for an arc from `from` to
    /// `to`.
    ///
    /// - Parameters:
    ///   - from: Tie origin (notehead anchor on the source side).
    ///   - to: Tie target (notehead anchor on the destination side).
    ///   - above: When `true`, the arc rises above the noteheads
    ///     (smaller y in y-down coords); when `false`, below.
    ///   - heightSp: Shoulder height in staff-spaces.
    ///   - headClearanceSp: How far off the notehead anchors the arc
    ///     starts/ends, in staff-spaces. Defaults to
    ///     `defaultHeadClearanceSp`.
    ///   - sp: Staff-space size in points.
    public static func controlPoints(
        from: CGPoint, to: CGPoint,
        above: Bool, heightSp: CGFloat,
        headClearanceSp: CGFloat = defaultHeadClearanceSp,
        sp: CGFloat,
    ) -> ControlPoints {
        let vertSign: CGFloat = above ? -1 : 1
        let headClearance = headClearanceSp * sp
        let startPt = CGPoint(x: from.x, y: from.y + headClearance * vertSign)
        let endPt = CGPoint(x: to.x, y: to.y + headClearance * vertSign)
        let dx = endPt.x - startPt.x
        let dy = endPt.y - startPt.y
        let shoulder = heightSp * sp * vertSign
        let p1 = CGPoint(
            x: startPt.x + dx * 0.2,
            y: startPt.y + dy * 0.2 + shoulder,
        )
        let p2 = CGPoint(
            x: startPt.x + dx * 0.8,
            y: startPt.y + dy * 0.8 + shoulder,
        )
        return ControlPoints(p0: startPt, p1: p1, p2: p2, p3: endPt)
    }

    // MARK: - The crescent a tie is filled as

    /// How far the crescent's two curves' control points stand off the centre line, in staff-spaces: zero width at the
    /// tips, `0.75 × 2 × 0.15 = 0.225 sp` thick at the shoulder — MuseScore's `tieMidWidth` (0.21 sp) give or take.
    public static let midThicknessSp: CGFloat = 0.15

    /// A tie as a closed, filled shape: two cubic curves sharing their ends, as MuseScore's
    /// `SlurTieLayout::computeBezier` makes it. Every renderer fills this one shape — the Apple `TieRenderer` and
    /// `ScoreLayerBuilder.drawTieArc`, and the draw program (`LayoutBridge.encodeTieArc`) the Android, web and
    /// Windows renderers draw — so a tie is the same crescent everywhere.
    public struct Crescent: Equatable, Sendable {
        /// Where both curves start and end: the tie's two tips.
        public let start: CGPoint
        public let end: CGPoint
        /// The outer curve's control points (further from the notes), drawn from `start` to `end`.
        public let outer1: CGPoint
        public let outer2: CGPoint
        /// The inner curve's control points (closer to the notes), drawn from `end` back to `start`.
        public let inner1: CGPoint
        public let inner2: CGPoint

        public init(
            start: CGPoint, end: CGPoint, outer1: CGPoint, outer2: CGPoint, inner1: CGPoint, inner2: CGPoint,
        ) {
            self.start = start
            self.end = end
            self.outer1 = outer1
            self.outer2 = outer2
            self.inner1 = inner1
            self.inner2 = inner2
        }
    }

    /// The crescent of a tie from `from` to `to` (notehead anchors) on the `above` side, `sp` points to the staff
    /// space: `controlPoints` at `shoulderHeightSp` for the tie's length, each control point moved `midThicknessSp`
    /// away from the notes for the outer curve and towards them for the inner one.
    public static func crescent(from: CGPoint, to: CGPoint, above: Bool, sp: CGFloat) -> Crescent {
        let points = controlPoints(
            from: from, to: to, above: above,
            heightSp: shoulderHeightSp(tieLengthSp: abs(to.x - from.x) / max(sp, .leastNonzeroMagnitude)),
            sp: sp,
        )
        let vertSign: CGFloat = above ? -1 : 1
        let thickDy = sp * midThicknessSp * vertSign * -1
        return Crescent(
            start: points.p0, end: points.p3,
            outer1: CGPoint(x: points.p1.x, y: points.p1.y - thickDy),
            outer2: CGPoint(x: points.p2.x, y: points.p2.y - thickDy),
            inner1: CGPoint(x: points.p2.x, y: points.p2.y + thickDy),
            inner2: CGPoint(x: points.p1.x, y: points.p1.y + thickDy),
        )
    }
}
