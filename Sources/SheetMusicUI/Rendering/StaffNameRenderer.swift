import SheetMusicLayout
import SwiftUI

/// Draws the instrument / staff name above a staff in the horizontal
/// continuous-view sticky pane.
///
/// MuseScore's `ContinuousPanel::paint` (continuouspanel.cpp:462-470)
/// places the staff name on the FIRST staff of each part at
/// `(clefLeftMargin + widthClef, -spatium * 2)`, drawn in
/// `TextStyleType::DEFAULT` — `defaultFontSize = 10.0 pt` (see
/// `styledef.cpp`), spatium-dependent. At MuseScore's reference
/// 5 pt spatium that lands at 2 spatia, so we render at `sp * 2.0`
/// with a bottom-leading anchor.
@available(macOS 15.0, iOS 16.0, *)
enum StaffNameRenderer {
    static func draw(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        guard !text.isEmpty else { return }
        context.drawExpressionText(
            text, at: origin,
            size: metrics.sp * 2.0,
            italic: false,
            anchor: .bottomLeading
        )
    }
}
