import CoreText
import SheetMusicCore
import SheetMusicLayout
import SheetMusicLayoutApple
import SwiftUI

/// Draws a `LayoutHarmony` into a SwiftUI `GraphicsContext`. Walks
/// the pre-laid-out `runs` list, switching font between the text
/// face (Edwin / Campania) and Bravura per run.
@available(macOS 15.0, *)
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
        let glyphFont = CTFontCreateWithName(
            BravuraFont.familyName as CFString,
            HarmonyRendering.glyphPointSize(
                for: lh.harmony, metrics: metrics,
            ), nil,
        )
        for run in lh.runs {
            let p = CGPoint(
                x: origin.x + CGFloat(run.x),
                y: origin.y,
            )
            switch run.kind {
            case .text:
                TextInkRenderer.draw(
                    context: &context, text: run.content, font: style.ctFont,
                    origin: p, anchor: CGPoint(x: 0, y: 0.5), color: textColor,
                )
            case let .accidental(acc):
                TextInkRenderer.draw(
                    context: &context, text: String(acc.codepoint), font: glyphFont,
                    origin: p, anchor: CGPoint(x: 0, y: 0.5), color: textColor,
                )
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
