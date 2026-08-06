import SheetMusicCore
import SheetMusicLayout
import SwiftUI

/// Draws free-form `<StaffText>` / `<SystemText>` from `.mscx`,
/// honoring the author's color. Position offsets are baked into
/// `origin` by `LayoutEngine+Placement` before this is called.
@available(macOS 15.0, *)
enum StaffTextRenderer {
    static func draw(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        color: ScoreColor?,
        style: TextStyleType = .staffText,
        properties: TextProperties = TextProperties(),
        metrics: StaffMetrics,
    ) {
        guard !text.isEmpty else { return }
        let swiftUIColor: Color = color.map(swiftUIColor(_:))
            ?? .primary
        let resolved = ResolvedTextStyle.resolve(
            style,
            overrides: properties,
            metrics: metrics,
        )
        let resolvedText = context.resolve(
            Text(text)
                .foregroundColor(swiftUIColor)
                .font(resolved.font),
        )
        context.draw(resolvedText, at: origin, anchor: .bottomLeading)
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
