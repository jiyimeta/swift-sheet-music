#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum TieRenderer {
    /// Draw a tie arc from one notehead origin to another.
    ///
    /// `from` and `to` are the notehead CENTERS — TieRenderer offsets
    /// the endpoints outward so the arc clears the notehead ink:
    ///
    /// - horizontally: start shifted right of head center, end shifted
    ///   left, so the curve doesn't overlap the noteheads on either
    ///   side.
    /// - vertically: shifted toward the tie side (above → top of head,
    ///   below → bottom) so the arc sits outside the notehead rather
    ///   than crossing through it.
    static func draw(
        context: inout GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        above: Bool,
        metrics: StaffMetrics
    ) {
        // Notehead half-extents (Bravura noteheadBlack ≈ 1.18 × 1.0 sp).
        let headHalfW = metrics.sp * 0.5
        // Half-height + clearance so the arc clears the notehead ink.
        let headHalfH = metrics.sp * 0.6
        let vertSign: CGFloat = above ? -1 : 1

        // Offset endpoints so the arc starts just past the notehead
        // edge on the tie side.
        let startPt = CGPoint(
            x: from.x + headHalfW,
            y: from.y + headHalfH * vertSign)
        let endPt = CGPoint(
            x: to.x - headHalfW,
            y: to.y + headHalfH * vertSign)

        // Control point: midway horizontally, pulled further away from
        // the noteheads by ~1.3 sp so the arc is clearly visible.
        let ctrlY = above
            ? min(startPt.y, endPt.y) - metrics.sp * 1.0
            : max(startPt.y, endPt.y) + metrics.sp * 1.0
        let ctrl = CGPoint(
            x: (startPt.x + endPt.x) / 2,
            y: ctrlY)

        var path = Path()
        path.move(to: startPt)
        path.addQuadCurve(to: endPt, control: ctrl)
        context.stroke(
            path,
            with: .color(.primary),
            lineWidth: metrics.sp * 0.13)
    }
}
#endif
