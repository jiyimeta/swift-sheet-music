#if os(macOS)
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
        metrics: StaffMetrics
    ) {
        guard count > 0 else { return }
        let radius = metrics.sp * 0.22
        // First dot sits about 1 sp right of the notehead's center.
        let firstOffset = metrics.sp * 1.15
        let spacing = metrics.sp * 0.6
        let y = onStaffLine ? origin.y - metrics.sp / 2 : origin.y
        for i in 0..<count {
            let x = origin.x + firstOffset + CGFloat(i) * spacing
            let rect = CGRect(
                x: x - radius,
                y: y - radius,
                width: radius * 2,
                height: radius * 2)
            context.fill(
                Path(ellipseIn: rect), with: .color(.primary))
        }
    }
}
#endif
