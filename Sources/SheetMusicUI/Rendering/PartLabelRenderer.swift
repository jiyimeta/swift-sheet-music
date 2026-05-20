import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum PartLabelRenderer {
    static func draw(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        guard !text.isEmpty else { return }
        context.drawExpressionText(
            text,
            at: origin,
            size: NotationTextStyle.fontSize(
                for: .partLabel, sp: metrics.sp,
            ),
            italic: NotationTextStyle.isItalic(for: .partLabel),
            anchor: .trailing,
        )
    }
}
