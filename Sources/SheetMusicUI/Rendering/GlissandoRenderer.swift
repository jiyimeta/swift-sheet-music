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
        // Font defaults via `TextStyleType.glissando` (Edwin 8 pt
        // italic, spatium-dependent). Width gating mirrors
        // `tdraw.cpp:1580` (`if (r.width() < l)`): when the rendered
        // label is at least as wide as the available line span,
        // MuseScore drops it instead of letting it crash through the
        // surrounding noteheads.
        if let text, !text.isEmpty {
            let style = ResolvedTextStyle.resolve(
                .glissando, metrics: metrics,
            )
            let label = Text(text)
                .foregroundColor(.primary)
                .font(style.font)
            let resolved = local.resolve(label)
            let textWidth = resolved.measure(in: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude,
            )).width
            if textWidth < length {
                // Place the text's descender bottom just above the
                // line — `tdraw.cpp:1584` raises the baseline by
                // 0.1 sp (straight) or 0.4 sp (wavy) above the
                // descender depth, which means the ink bottom ends
                // at exactly that clearance above the line.
                let clearance = metrics.sp * (wavy ? 0.4 : 0.1)
                let textX = length / 2
                local.draw(
                    resolved,
                    at: CGPoint(x: textX, y: -clearance),
                    anchor: UnitPoint(x: 0.5, y: 1.0),
                )
            }
        }
    }
}
