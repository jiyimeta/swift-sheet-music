import SheetMusicCore
import SheetMusicLayout
import SwiftUI

/// Draws a `LayoutHarmony` into a SwiftUI `GraphicsContext`. Walks
/// the pre-laid-out `runs` list, switching font between the text
/// face (Edwin / Campania) and Bravura per run.
@available(macOS 15.0, iOS 16.0, *)
enum HarmonyRenderer {
    static func draw(
        context: inout GraphicsContext,
        harmony lh: LayoutHarmony,
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        guard !lh.runs.isEmpty else { return }
        let style = ResolvedTextStyle.resolve(
            lh.harmony.styleType,
            overrides: lh.harmony.properties,
            metrics: metrics,
        )
        let textColor: Color = lh.harmony.color.map(swiftUIColor)
            ?? .primary
        let glyphFont = Font.custom(
            BravuraFont.familyName,
            size: HarmonyRendering.glyphPointSize(
                for: lh.harmony, metrics: metrics,
            ),
        )
        for run in lh.runs {
            let p = CGPoint(
                x: origin.x + CGFloat(run.x),
                y: origin.y,
            )
            switch run.kind {
            case .text:
                let resolved = context.resolve(
                    Text(run.content)
                        .font(style.font)
                        .foregroundColor(textColor),
                )
                context.draw(resolved, at: p, anchor: .leading)
            case let .accidental(acc):
                let resolved = context.resolve(
                    Text(String(acc.codepoint))
                        .font(glyphFont)
                        .foregroundColor(textColor),
                )
                context.draw(resolved, at: p, anchor: .leading)
            }
        }
    }

    private static func swiftUIColor(_ color: ScoreColor) -> Color {
        Color(
            red: Double(color.red) / 255,
            green: Double(color.green) / 255,
            blue: Double(color.blue) / 255,
            opacity: Double(color.alpha) / 255,
        )
    }
}
