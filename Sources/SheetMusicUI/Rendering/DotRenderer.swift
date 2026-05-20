import SheetMusicLayout
import SwiftUI

/// Augmentation dots drawn to the right of a notehead or rest glyph.
/// Small filled circle; offset by ~1 sp right of the anchor, further
/// dots spaced ~0.5 sp apart.
@available(macOS 15.0, *)
enum DotRenderer {
    /// Draw `count` dots after `origin`. `onLineY` is true when the
    /// anchor sits on a staff line (even staff step) — the first dot
    /// is shifted half a space up into the adjacent line-gap, per
    /// standard engraving convention. For anchors already in a space
    /// (odd step) the dot stays on the same y.
    static func draw(
        context: inout GraphicsContext,
        after origin: CGPoint,
        count: Int,
        onStaffLine: Bool,
        metrics: StaffMetrics,
    ) {
        guard count > 0 else { return }
        let radius = DotGeometry.radiusSp * metrics.sp
        let centers = DotGeometry.centers(
            after: origin, count: count,
            onStaffLine: onStaffLine, sp: metrics.sp,
        )
        for center in centers {
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2,
            )
            context.fill(
                Path(ellipseIn: rect), with: .color(.primary),
            )
        }
    }
}
