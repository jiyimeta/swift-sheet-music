import SheetMusicLayout
import SwiftUI

/// The multi-measure rest for the SwiftUI Canvas renderer: the SMuFL H-bar at the measure's center on the staff's
/// middle line, and the run length above it. The same two marks `ScoreLayerBuilder.drawMultiMeasureRest` draws for
/// the CALayer renderer, at the same anchors — until this existed the Canvas path drew nothing at all, so a PDF of a
/// collapsed rest run printed an empty bar.
@available(macOS 15.0, *)
enum MultiMeasureRestRenderer {
    static func draw(
        context: inout GraphicsContext,
        count: Int,
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        context.drawGlyph(SMuFLGlyph.restHBar, at: origin, size: metrics.glyphFontSize)
        // `0` draws the bar alone: the lower staves of a system, which do not repeat the run length.
        guard count > 0 else { return }
        let style = ResolvedTextStyle.resolve(.tempo, metrics: metrics)
        let text = context.resolve(
            Text(String(count)).font(Font(style.ctFont)).foregroundColor(.primary),
        )
        context.draw(text, at: CGPoint(x: origin.x, y: origin.y - metrics.sp * 2.5), anchor: .center)
    }
}
