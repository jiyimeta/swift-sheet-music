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
    static func draw(
        context: inout GraphicsContext,
        anchor: TremoloAnchor,
        barCount: Int,
        metrics: StaffMetrics,
    ) {
        let bars = TremoloGeometry.bars(
            anchor: anchor, barCount: barCount, sp: metrics.sp,
        )
        guard !bars.isEmpty else { return }
        let thickness = TremoloGeometry.barThickness(sp: metrics.sp)
        // Slant left-low → right-high (visually rising), matching
        // MuseScore's tremolo bar convention regardless of stem
        // direction.
        for bar in bars {
            var path = Path()
            path.move(to: bar.from)
            path.addLine(to: bar.to)
            context.stroke(
                path, with: .color(.primary), lineWidth: thickness,
            )
        }
    }
}
