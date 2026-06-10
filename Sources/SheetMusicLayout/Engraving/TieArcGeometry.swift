#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

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
}
