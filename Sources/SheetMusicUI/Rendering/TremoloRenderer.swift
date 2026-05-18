import CoreGraphics
import SheetMusicLayout
import SwiftUI

/// Draws the slanted bars of a tremolo decoration: either crossing a
/// single chord's stem (`.single`) or spanning between two chord stems
/// (`.between`).
///
/// Each bar is a thin rectangle of thickness `metrics.sp * 0.5`
/// (matching `ScoreLayerBuilder.drawBeam`'s beam thickness), spaced
/// by `metrics.sp * 0.3` (matching beam gap). v1 uses a fixed +12°
/// slant — MuseScore picks chord-specific slants but the constant
/// matches the default the vast majority of the time and avoids
/// carrying beam state into the tremolo emitter. Shared with the
/// `CALayer` path in `ScoreLayerBuilder+Spanners`.
@available(macOS 15.0, *)
enum TremoloRenderer {
    /// Beam-bar thickness, matching `drawBeam`.
    static func barThickness(metrics: StaffMetrics) -> CGFloat {
        metrics.sp * 0.5
    }

    /// Gap between successive bars, matching `drawBeam`.
    static func barSpacing(metrics: StaffMetrics) -> CGFloat {
        metrics.sp * 0.8 // thickness (0.5 sp) + gap (0.3 sp)
    }

    /// Geometry shared by both rendering surfaces. `halfWidth` is
    /// the horizontal half-length of each bar; `slantDy` is the
    /// vertical run between centre and either endpoint (matches a
    /// +12° slant); `center` is the bars' shared anchor.
    static func geometry(
        anchor: TremoloAnchor,
        metrics: StaffMetrics,
    ) -> (center: CGPoint, halfWidth: CGFloat, slantDy: CGFloat) {
        let center: CGPoint
        let halfWidth: CGFloat
        switch anchor {
        case let .single(top, bottom):
            center = CGPoint(
                x: top.x,
                y: (top.y + bottom.y) / 2,
            )
            halfWidth = metrics.sp * 0.9
        case let .between(left, right):
            center = CGPoint(
                x: (left.x + right.x) / 2,
                y: (left.y + right.y) / 2,
            )
            halfWidth = max(
                metrics.sp * 0.3,
                (right.x - left.x) / 2 - metrics.sp * 0.2,
            )
        }
        let slantDy = halfWidth * tan(.pi / 15) // +12° (~0.2126)
        return (center, halfWidth, slantDy)
    }

    static func draw(
        context: inout GraphicsContext,
        anchor: TremoloAnchor,
        barCount: Int,
        metrics: StaffMetrics,
    ) {
        guard barCount > 0 else { return }
        let (center, halfWidth, slantDy) = geometry(
            anchor: anchor, metrics: metrics,
        )
        let thickness = barThickness(metrics: metrics)
        let spacing = barSpacing(metrics: metrics)
        let firstOffset = -CGFloat(barCount - 1) / 2 * spacing
        for i in 0 ..< barCount {
            let offsetY = firstOffset + CGFloat(i) * spacing
            var path = Path()
            // Slant left-low → right-high (visually rising), matching
            // MuseScore's tremolo bar convention regardless of stem
            // direction. Screen y grows downward, so left = +slantDy.
            path.move(to: CGPoint(
                x: center.x - halfWidth,
                y: center.y + offsetY + slantDy,
            ))
            path.addLine(to: CGPoint(
                x: center.x + halfWidth,
                y: center.y + offsetY - slantDy,
            ))
            context.stroke(
                path, with: .color(.primary), lineWidth: thickness,
            )
        }
    }
}
