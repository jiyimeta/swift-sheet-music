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
        let length = GlissandoGeometry.length(from: from, to: to)
        guard length > 0.01 else { return }
        let angle = GlissandoGeometry.angle(from: from, to: to)

        // Work in a rotated coordinate system anchored at `from`, so
        // the line runs horizontally from (0, 0) to (length, 0).
        var local = context
        local.translateBy(x: from.x, y: from.y)
        local.concatenate(CGAffineTransform(rotationAngle: angle))

        // --- Line ---
        let points = GlissandoGeometry.linePoints(
            length: length, wavy: wavy, sp: metrics.sp,
        )
        var linePath = Path()
        if let first = points.first {
            linePath.move(to: first)
            for pt in points.dropFirst() {
                linePath.addLine(to: pt)
            }
        }
        local.stroke(
            linePath, with: .color(.primary),
            lineWidth: metrics.sp * GlissandoGeometry.lineThicknessSp,
        )

        // --- Text label (centered along the line) ---
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
                let anchor = GlissandoGeometry.textAnchorLocal(
                    length: length, wavy: wavy, sp: metrics.sp,
                )
                local.draw(
                    resolved,
                    at: anchor,
                    anchor: UnitPoint(x: 0.5, y: 1.0),
                )
            }
        }
    }
}
