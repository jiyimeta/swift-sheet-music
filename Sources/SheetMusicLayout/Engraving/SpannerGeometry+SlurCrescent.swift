#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// A slur as MuseScore fills it: a crescent around the slur's curve, thickest at the shoulder and `slurEndWidthSp`
/// wide at the tips (folino owner's call, 2026-11-21; until then every renderer stroked the curve at a constant
/// `strokeThicknessSp`).
///
/// MuseScore (`SlurTieLayout::computeBezier`, `computeMidThickness`) moves the curve's two control points
/// `midThickness` away from the chord on the shoulder's side for the outer curve and towards it for the inner one, and
/// `TDraw::draw(SlurSegment)` fills that shape and strokes its outline with an `endWidth` pen, round-joined, which is
/// what gives the tips their width. Here the outline is folded into the one filled shape instead — each tip opened
/// `slurEndWidthSp` wide and each control point moved a further `slurEndWidthSp / 2`, so the shoulder is
/// `0.75 × 2 × midThickness + slurEndWidthSp` thick as MuseScore's is (at t = ½ a cubic's ends weigh ¼, its control
/// points ¾) — since a draw-program stroke has no round join and a sharp tip would spike out on a miter. Every renderer
/// fills this shape: the Apple `SpannerRenderer` and `ScoreLayerBuilder`, and the draw program the Android, web and
/// Windows renderers draw. The curve itself is still `slurControlPoint`'s.
extension SpannerGeometry {
    /// MuseScore's `slurEndWidth` (`styledef.cpp:614`): the width at the tips.
    public static let slurEndWidthSp: CGFloat = 0.05
    /// MuseScore's `slurMidWidth` (`styledef.cpp:615`).
    public static let slurMidWidthSp: CGFloat = 0.21

    /// MuseScore's `computeMidThickness` for a solid slur `lengthSp` staff spaces long: how far each control point
    /// moves off the curve. `slurMidWidthSp − slurEndWidthSp` (0.16 sp) beyond 4 sp; shorter, on the line from
    /// `0.15 − slurEndWidthSp` (0.10 sp) at MuseScore's `minTieLength` (1 sp) up to it, never above it.
    public static func slurMidThicknessSp(lengthSp: CGFloat) -> CGFloat {
        let minLength: CGFloat = 1
        let shortLimit: CGFloat = 4
        let minThickness = 0.15 - slurEndWidthSp
        let normal = slurMidWidthSp - slurEndWidthSp
        guard lengthSp <= shortLimit else { return normal }
        let a = 1 / (shortLimit - minLength)
        let b = normal - minThickness
        let c = shortLimit * minThickness - minLength * normal
        return min(a * (b * lengthSp + c), normal)
    }

    /// A slur's filled shape: the outer curve from one tip to the other, a straight edge across the far tip, the inner
    /// curve back, and the near tip closes it.
    public struct SlurCrescent: Equatable, Sendable {
        /// The outer curve (on the shoulder's side): from `outerStart` to `outerEnd`.
        public let outerStart: CGPoint
        public let outer1: CGPoint
        public let outer2: CGPoint
        public let outerEnd: CGPoint
        /// The inner curve (on the chord's side): from `innerStart` (across the far tip from `outerEnd`) back to
        /// `innerEnd` (across the near tip from `outerStart`).
        public let innerStart: CGPoint
        public let inner1: CGPoint
        public let inner2: CGPoint
        public let innerEnd: CGPoint

        public init(
            outerStart: CGPoint, outer1: CGPoint, outer2: CGPoint, outerEnd: CGPoint,
            innerStart: CGPoint, inner1: CGPoint, inner2: CGPoint, innerEnd: CGPoint,
        ) {
            self.outerStart = outerStart
            self.outer1 = outer1
            self.outer2 = outer2
            self.outerEnd = outerEnd
            self.innerStart = innerStart
            self.inner1 = inner1
            self.inner2 = inner2
            self.innerEnd = innerEnd
        }
    }

    /// The crescent of a slur from `from` to `to`, `sp` points to the staff space: `slurControlPoint`'s curve as a
    /// cubic (control points at the quadratic's thirds), thickened perpendicular to the chord from `from` to `to`.
    public static func slurCrescent(from: CGPoint, to: CGPoint, sp: CGFloat) -> SlurCrescent {
        let control = slurControlPoint(from: from, to: to, sp: sp)
        let c1 = CGPoint(x: (from.x + 2 * control.x) / 3, y: (from.y + 2 * control.y) / 3)
        let c2 = CGPoint(x: (to.x + 2 * control.x) / 3, y: (to.y + 2 * control.y) / 3)
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        // The unit normal to the chord, turned towards the shoulder (the side the control point bulges to).
        var normal = length > 0 ? CGPoint(x: -dy / length, y: dx / length) : CGPoint(x: 0, y: -1)
        if (control.x - from.x) * normal.x + (control.y - from.y) * normal.y < 0 {
            normal = CGPoint(x: -normal.x, y: -normal.y)
        }
        let tip = sp * slurEndWidthSp / 2
        let shoulder = sp * slurMidThicknessSp(lengthSp: length / max(sp, .leastNonzeroMagnitude)) + tip
        func moved(_ point: CGPoint, by distance: CGFloat) -> CGPoint {
            CGPoint(x: point.x + normal.x * distance, y: point.y + normal.y * distance)
        }
        return SlurCrescent(
            outerStart: moved(from, by: tip), outer1: moved(c1, by: shoulder), outer2: moved(c2, by: shoulder),
            outerEnd: moved(to, by: tip),
            innerStart: moved(to, by: -tip), inner1: moved(c2, by: -shoulder), inner2: moved(c1, by: -shoulder),
            innerEnd: moved(from, by: -tip),
        )
    }
}
