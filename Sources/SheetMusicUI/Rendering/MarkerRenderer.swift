import SheetMusicCore
import SheetMusicLayout
import SwiftUI

/// A marker is its text's runs — a segno or coda included, a symbol run of that text — hung by the anchor its kind is
/// set at (`LayoutRichText.anchor(for:)`), in its author color (`nil` = ink). One without runs draws nothing.
@available(macOS 15.0, *)
enum MarkerRenderer {
    static func draw(
        context: inout GraphicsContext,
        kind: Marker.Kind,
        origin: CGPoint,
        richText: LayoutRichText?,
        color: ScoreColor?,
    ) {
        guard let richText else { return }
        TextInkRenderer.drawRich(
            context: &context, richText: richText, origin: origin,
            anchor: LayoutRichText.anchor(for: .forMarker(kind)),
            color: color.map { Color(scoreColor: $0) } ?? .primary,
        )
    }
}
