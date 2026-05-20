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

        let resolved = context.resolve(
            Text(text)
                .foregroundColor(textColor)
                .font(style.font),
        )
        let measured = resolved.measure(in: CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude,
        ))

        // Anchor the text bottom-leading at `(origin.x + pad,
        // origin.y - pad)` so the surrounding box's lower-left
        // corner ends up at `origin`.
        let textOrigin = CGPoint(
            x: origin.x + pad, y: origin.y - pad,
        )
        context.draw(
            resolved, at: textOrigin,
            anchor: UnitPoint(x: 0, y: 1),
        )

        let boxRect = RehearsalMarkFrame.boxRect(
            textWidth: measured.width,
            textHeight: measured.height,
            origin: origin,
            pad: pad,
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
