import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum JumpRenderer {
    static func draw(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        guard !text.isEmpty else { return }
        context.drawExpressionText(
            text, at: origin,
            size: NotationTextStyle.fontSize(for: .jump, sp: metrics.sp),
            italic: NotationTextStyle.isItalic(for: .jump),
        )
    }
}
