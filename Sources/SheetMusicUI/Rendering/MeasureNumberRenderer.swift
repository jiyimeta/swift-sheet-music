import SheetMusicLayout
import SwiftUI

/// Draws the measure-number label that engraving convention places
/// above the first measure of every system.
///
/// Sized to match the staff-name font (`sp * 2.0`, MuseScore's
/// `TextStyleType::DEFAULT` at 10 pt / 5 pt-spatium ≈ 2 spatia).
/// Anchored BOTTOM-LEADING so the digits' LEFT edge lines up with
/// the bracket / leading barline and grow rightward as the number
/// widens, never leftward into the gutter where they'd be clipped
/// by the system or sticky frame.
@available(macOS 15.0, *)
enum MeasureNumberRenderer {
    static func draw(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        guard !text.isEmpty else { return }
        context.drawExpressionText(
            text, at: origin,
            size: NotationTextStyle.fontSize(
                for: .measureNumber, sp: metrics.sp,
            ),
            italic: NotationTextStyle.isItalic(for: .measureNumber),
            anchor: .bottomLeading,
        )
    }
}
