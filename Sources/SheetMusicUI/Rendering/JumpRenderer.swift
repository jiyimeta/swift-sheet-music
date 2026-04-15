#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum JumpRenderer {
    static func draw(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        guard !text.isEmpty else { return }
        context.drawExpressionText(
            text, at: origin,
            size: metrics.sp * 2.5, italic: true)
    }
}
#endif
