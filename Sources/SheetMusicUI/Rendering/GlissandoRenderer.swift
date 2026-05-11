import SheetMusicLayout
import SwiftUI

/// Draws a glissando line (straight or wavy) between two noteheads,
/// with an optional text label ("gliss.", etc.) that follows the
/// slope of the line — matching MuseScore's rotated-painter approach
/// (`tdraw.cpp::draw(GlissandoSegment)`).
@available(macOS 15.0, iOS 16.0, *)
enum GlissandoRenderer {
    static func draw(
        context: inout GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        wavy: Bool,
        text: String?,
        metrics: StaffMetrics,
    ) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0.01 else { return }
        let angle = atan2(dy, dx) // radians, screen-coords

        // Work in a rotated coordinate system anchored at `from`, so
        // the line runs horizontally from (0, 0) to (length, 0).
        var local = context
        local.translateBy(x: from.x, y: from.y)
        local.concatenate(CGAffineTransform(rotationAngle: angle))

        // --- Line ---
        var linePath = Path()
        if wavy {
            let waveAmp = metrics.sp * 0.3
            let segments = max(3, Int(length / (metrics.sp * 0.8)))
            let segLen = length / CGFloat(segments)
            linePath.move(to: .zero)
            for i in 1 ... segments {
                let x = segLen * CGFloat(i)
                let y = i.isMultiple(of: 2) ? waveAmp : -waveAmp
                linePath.addLine(to: CGPoint(x: x, y: y))
            }
        } else {
            linePath.move(to: .zero)
            linePath.addLine(to: CGPoint(x: length, y: 0))
        }
        local.stroke(
            linePath, with: .color(.primary),
            lineWidth: metrics.sp * 0.15,
        )

        // --- Text label (centred along the line) ---
        if let text, !text.isEmpty {
            let fontSize = metrics.sp * 1.8
            // MuseScore raises the text slightly above the line.
            let yOffset = -(metrics.sp * 0.5)
            let textX = length / 2
            local.drawExpressionText(
                text,
                at: CGPoint(x: textX, y: yOffset),
                size: fontSize,
                italic: true,
                anchor: .center,
            )
        }
    }
}
