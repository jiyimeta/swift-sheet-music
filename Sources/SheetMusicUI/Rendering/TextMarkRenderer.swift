import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
enum TextMarkRenderer {
    /// Dynamic marking (pp, p, mf, f, ff, …). Italic, bold, below staff.
    static func drawDynamic(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        context.drawExpressionText(
            text,
            at: origin,
            size: metrics.sp * 2.5,
            italic: true
        )
    }

    /// Tempo indication ("♩ = 120"). Upright, bold, above staff.
    static func drawTempo(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        context.drawExpressionText(
            text,
            at: origin,
            size: metrics.sp * 2.2,
            italic: false
        )
    }
}
