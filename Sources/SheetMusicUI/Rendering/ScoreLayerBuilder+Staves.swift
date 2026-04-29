import QuartzCore
import SheetMusicCore
import SheetMusicLayout

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@available(macOS 15.0, iOS 16.0, *)
extension ScoreLayerBuilder {
    // MARK: - Staves, bracket, part labels

    static func drawStaves(
        system: LayoutSystem,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        for origin in system.staffOrigins {
            let path = CGMutablePath()
            let width = system.size.width - origin.x
            for i in 0..<5 {
                let y = origin.y + CGFloat(i) * metrics.sp
                path.move(to: CGPoint(x: origin.x, y: y))
                path.addLine(
                    to: CGPoint(x: origin.x + width, y: y))
            }
            parent.addSublayer(strokeLayer(
                path: path,
                height: height,
                lineWidth: metrics.staffLineThickness))
        }
    }

    static func drawBracket(
        system: LayoutSystem,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        guard system.staffOrigins.count >= 2,
              let top = system.staffOrigins.first,
              let bot = system.staffOrigins.last
        else { return }
        let x = top.x - metrics.sp * 0.5
        let topPt = CGPoint(x: x, y: top.y)
        let botPt = CGPoint(x: x, y: bot.y + metrics.staffHeight)

        let spine = CGMutablePath()
        spine.move(to: topPt)
        spine.addLine(to: botPt)
        parent.addSublayer(strokeLayer(
            path: spine,
            height: height,
            lineWidth: metrics.sp * 0.3))

        for point in [topPt, botPt] {
            let serif = CGMutablePath()
            serif.move(to: point)
            serif.addLine(to: CGPoint(
                x: point.x + metrics.sp * 0.8, y: point.y))
            parent.addSublayer(strokeLayer(
                path: serif,
                height: height,
                lineWidth: metrics.sp * 0.25))
        }
    }

    static func drawPartLabels(
        system: LayoutSystem,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        for label in system.partLabels {
            guard !label.text.isEmpty else { continue }
            let origin = CGPoint(
                x: (system.staffOrigins.first?.x ?? 60) - metrics.sp,
                y: label.origin.y)
            if let layer = textLayer(
                text: label.text,
                at: origin,
                size: metrics.sp * 2.5,
                italic: false,
                anchor: CGPoint(x: 1, y: 0.5),
                height: height) {
                parent.addSublayer(layer)
            }
        }
    }
}
