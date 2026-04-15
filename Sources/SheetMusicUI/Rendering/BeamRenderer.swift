#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum BeamRenderer {
    /// Draw `levels` stacked beam bars from `from` to `to`. v1 uses flat
    /// (horizontal) beams — real engraving slopes them, but we can defer
    /// that.
    static func draw(
        context: inout GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        levels: Int,
        metrics: StaffMetrics
    ) {
        let beamThickness = metrics.sp * 0.5
        let beamGap = metrics.sp * 0.3
        // v1: stack levels below the "from" y (assumes stem-down); for
        // stem-up they should stack above. Since we don't yet know stem
        // direction here, emit level bars growing downward from `from.y`;
        // if beaming looks wrong on stem-up groups, Stage 7 follow-up can
        // accept a direction parameter.
        for lv in 0..<max(0, levels) {
            let dy = CGFloat(lv) * (beamThickness + beamGap)
            var path = Path()
            path.move(to: CGPoint(x: from.x, y: from.y + dy))
            path.addLine(to: CGPoint(x: to.x, y: to.y + dy))
            path.addLine(
                to: CGPoint(x: to.x, y: to.y + dy + beamThickness))
            path.addLine(
                to: CGPoint(x: from.x, y: from.y + dy + beamThickness))
            path.closeSubpath()
            context.fill(path, with: .color(.primary))
        }
    }
}
#endif
