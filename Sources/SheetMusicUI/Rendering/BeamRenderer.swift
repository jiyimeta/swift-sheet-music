import SwiftUI
import SheetMusicLayout

@available(macOS 15.0, iOS 16.0, *)
enum BeamRenderer {
    /// Draw a single beam bar at `level` (1 = primary, 2 = first
    /// secondary, etc.). `direction` is the group's stem direction —
    /// secondary bars stack toward the noteheads (downward for
    /// stem-up, upward for stem-down).
    ///
    /// v1 uses flat (horizontal) beams — real engraving slopes them to
    /// track the chord contour, but for v1 the note y at each
    /// endpoint is ignored and the bar sits at `from.y` + level-offset.
    static func draw(
        context: inout GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        direction: StemDirection,
        level: Int,
        metrics: StaffMetrics
    ) {
        guard level >= 1 else { return }
        let beamThickness = metrics.sp * 0.5
        let beamGap = metrics.sp * 0.3
        let stackSign: CGFloat = direction == .up ? 1 : -1
        let dy = CGFloat(level - 1) * (beamThickness + beamGap) * stackSign
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
