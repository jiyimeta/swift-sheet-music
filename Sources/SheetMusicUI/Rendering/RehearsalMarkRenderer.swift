import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
enum RehearsalMarkRenderer {
    static func draw(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        frame: RehearsalMark.FrameKind,
        color: ScoreColor?,
        metrics: StaffMetrics
    ) {
        guard !text.isEmpty else { return }
        // MuseScore defaults: `Sid::rehearsalMarkFontSize` = 14pt with
        // FontSpatiumDependent ⇒ 14/5 = 2.8 sp.
        // `Sid::rehearsalMarkFramePadding` = 0.5 sp.
        let textSize = metrics.sp * 2.8
        let pad = metrics.sp * 0.5

        let textColor: Color
        if let c = color {
            textColor = Color(
                red: Double(c.red) / 255,
                green: Double(c.green) / 255,
                blue: Double(c.blue) / 255,
                opacity: Double(c.alpha) / 255
            )
        } else {
            textColor = .primary
        }

        let resolved = context.resolve(
            Text(text)
                .foregroundColor(textColor)
                .font(.system(size: textSize, weight: .semibold)))
        let measured = resolved.measure(in: CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))

        // Anchor the text bottom-leading at `(origin.x + pad,
        // origin.y - pad)` so the surrounding box's lower-left
        // corner ends up at `origin`.
        let textOrigin = CGPoint(
            x: origin.x + pad, y: origin.y - pad
        )
        context.draw(
            resolved, at: textOrigin,
            anchor: UnitPoint(x: 0, y: 1)
        )

        let boxWidth = measured.width + 2 * pad
        let boxHeight = measured.height + 2 * pad
        let boxRect = CGRect(
            x: origin.x,
            y: origin.y - boxHeight,
            width: boxWidth,
            height: boxHeight
        )
        // `Sid::rehearsalMarkFrameWidth` default.
        let lineWidth = metrics.sp * 0.16
        var framePath: Path?
        switch frame {
        case .none:
            framePath = nil
        case .rectangle:
            framePath = Path(boxRect)
        case .circle:
            let diameter = max(boxRect.width, boxRect.height)
            framePath = Path(ellipseIn: CGRect(
                x: boxRect.midX - diameter / 2,
                y: boxRect.midY - diameter / 2,
                width: diameter,
                height: diameter
            ))
        }
        if let p = framePath {
            context.stroke(
                p, with: .color(textColor),
                lineWidth: lineWidth
            )
        }
    }
}
