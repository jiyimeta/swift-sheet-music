import SheetMusicCore
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum MarkerRenderer {
    static func draw(
        context: inout GraphicsContext,
        kind: Marker.Kind,
        text: String,
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        switch MarkerGlyph.variant(for: kind, text: text) {
        case let .glyph(codepoint):
            // swiftlint:disable:next force_unwrapping
            let glyph = Character(UnicodeScalar(codepoint)!)
            context.drawGlyph(
                glyph, at: origin, size: metrics.glyphFontSize,
            )
        case let .text(label):
            context.drawExpressionText(
                label, at: origin,
                size: NotationTextStyle.fontSize(
                    for: .markerText, sp: metrics.sp,
                ),
                italic: NotationTextStyle.isItalic(for: .markerText),
            )
        }
    }
}
