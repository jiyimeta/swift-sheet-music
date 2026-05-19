import SheetMusicLayout
import SwiftUI

/// Draws a glissando line (straight or wavy) between two noteheads,
/// with an optional text label ("gliss.", etc.) that follows the
/// slope of the line — matching MuseScore's rotated-painter approach
/// (`tdraw.cpp::draw(GlissandoSegment)`).
@available(macOS 15.0, *)
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
        // Mirrors `tdraw.cpp:1580` (`if (r.width() < l)`): when the
        // rendered text would be at least as wide as the available
        // line span, MuseScore silently drops it instead of letting
        // it crash through the start/end noteheads. Measuring via
        // SwiftUI's resolved Text guarantees we compare against the
        // exact glyph metrics the renderer will draw — CTFont with
        // trait descriptors under-reports italic-semibold width and
        // leaves the gate too loose.
        if let text, !text.isEmpty {
            let fontSize = metrics.sp * 1.8
            let label = Text(text).font(
                .system(size: fontSize, weight: .semibold).italic(),
            )
            let resolved = local.resolve(label)
            let textWidth = resolved.measure(in: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude,
            )).width
            if textWidth < length {
                let yOffset = -(metrics.sp * 0.5)
                let textX = length / 2
                local.draw(
                    resolved,
                    at: CGPoint(x: textX, y: yOffset),
                    anchor: .center,
                )
            }
        }
    }
}
