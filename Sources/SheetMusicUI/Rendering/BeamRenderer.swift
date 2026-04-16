#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum BeamRenderer {
    /// Draw `levels` stacked beam bars from `from` to `to`. v1 uses flat
    /// (horizontal) beams — real engraving slopes them, but we can defer
    /// that.
    ///
    /// `direction` is the group's stem direction: bars stack on the stem
    /// side so additional beam levels sit between the primary beam and
    /// the noteheads.
    static func draw(
        context: inout GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        levels: Int,
        direction: StemDirection,
        metrics: StaffMetrics
    ) {
        let beamThickness = metrics.sp * 0.5
        let beamGap = metrics.sp * 0.3
        // Stem-up → beam is above notes, extra bars grow downward
        // (toward the notes). Stem-down → beam is below notes, extra
        // bars grow upward. sign is the stacking direction.
        let stackSign: CGFloat = direction == .up ? 1 : -1
        for lv in 0..<max(0, levels) {
            let dy = CGFloat(lv) * (beamThickness + beamGap) * stackSign
            let barInner = dy
            let barOuter = dy + beamThickness * stackSign
            var path = Path()
            path.move(to: CGPoint(x: from.x, y: from.y + barInner))
            path.addLine(to: CGPoint(x: to.x, y: to.y + barInner))
            path.addLine(to: CGPoint(x: to.x, y: to.y + barOuter))
            path.addLine(to: CGPoint(x: from.x, y: from.y + barOuter))
            path.closeSubpath()
            context.fill(path, with: .color(.primary))
        }
    }
}
#endif
