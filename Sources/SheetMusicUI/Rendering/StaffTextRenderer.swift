import SheetMusicCore
import SheetMusicLayout
import SwiftUI

/// Draws free-form `<StaffText>` / `<SystemText>` from `.mscx`,
/// honouring the author's colour. Position offsets are baked into
/// `origin` by `LayoutEngine+Placement` before this is called.
@available(macOS 15.0, iOS 16.0, *)
enum StaffTextRenderer {
    static func draw(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        color: ScoreColor?,
        isSystemText: Bool = false,
        properties: TextProperties = TextProperties(),
        metrics: StaffMetrics,
    ) {
        guard !text.isEmpty else { return }
        let swiftUIColor: Color = color.map(swiftUIColor(_:))
            ?? .primary
        let style = ResolvedTextStyle.resolve(
            isSystemText ? .systemText : .staffText,
            overrides: properties,
            metrics: metrics,
        )
        let resolved = context.resolve(
            Text(text)
                .foregroundColor(swiftUIColor)
                .font(style.font),
        )
        context.draw(resolved, at: origin, anchor: .bottomLeading)
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
