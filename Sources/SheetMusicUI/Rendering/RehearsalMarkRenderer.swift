import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum RehearsalMarkRenderer {
    static func draw(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        frame: TextFrameType,
        color: ScoreColor?,
        properties: TextProperties = TextProperties(),
        metrics: StaffMetrics,
    ) {
        guard !text.isEmpty else { return }
        // MuseScore defaults via TextStyleType.rehearsalMark:
        // Edwin 14 pt bold, frameType=square, framePadding=0.5 sp.
        let style = ResolvedTextStyle.resolve(
            .rehearsalMark, overrides: properties, metrics: metrics,
        )
        let pad = style.framePadding

        let textColor: Color
        if let c = color {
            textColor = Color(
                red: Double(c.red) / 255,
                green: Double(c.green) / 255,
                blue: Double(c.blue) / 255,
                opacity: Double(c.alpha) / 255,
            )
        } else {
            textColor = .primary
        }

        // Anchor the text bottom-leading at `(origin.x + pad,
        // origin.y - pad)` so the surrounding box's lower-left
        // corner ends up at `origin`.
        let textOrigin = CGPoint(
            x: origin.x + pad, y: origin.y - pad,
        )
        TextInkRenderer.draw(
            context: &context, text: text, font: style.ctFont,
            origin: textOrigin, anchor: CGPoint(x: 0, y: 1), color: textColor,
        )
        let boxRect = TextInkGeometry.rehearsalBox(
            text: text, font: TextInkGeometry.font(for: .rehearsalMark, overrides: properties, metrics: metrics),
            origin: origin, sp: metrics.sp,
        )
        let strokeWidth = RehearsalMarkFrame.strokeWidthSp(
            sp: metrics.sp,
        )
        switch RehearsalMarkFrame.shape(for: frame, around: boxRect) {
        case .none:
            break
        case let .rectangle(rect):
            context.stroke(
                Path(rect), with: .color(textColor),
                lineWidth: strokeWidth,
            )
        case let .ellipse(rect):
            context.stroke(
                Path(ellipseIn: rect), with: .color(textColor),
                lineWidth: strokeWidth,
            )
        }
    }
}
