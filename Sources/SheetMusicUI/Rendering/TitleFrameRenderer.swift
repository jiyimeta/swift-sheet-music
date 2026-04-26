import SheetMusicCore
import SwiftUI

/// Draws the texts of a `LayoutTitleFrame` (resolved positions +
/// font sizes) into a `GraphicsContext`. Used by both the on-screen
/// `ScoreView` and the PDF exporter so the title block matches
/// across surfaces.
@available(macOS 15.0, iOS 16.0, *)
public enum TitleFrameRenderer {
    public static func draw(
        _ frame: LayoutTitleFrame,
        into context: inout GraphicsContext,
        origin: CGPoint = .zero
    ) {
        for entry in frame.texts {
            let styled = Text(entry.text)
                .font(font(for: entry.style, size: entry.fontSize))
                .foregroundColor(.black)
            let resolved = context.resolve(styled)
            let pos = CGPoint(
                x: origin.x + entry.position.x,
                y: origin.y + entry.position.y)
            context.draw(
                resolved, at: pos, anchor: anchor(for: entry.anchor))
        }
    }

    private static func font(
        for style: FrameText.Style, size: CGFloat
    ) -> Font {
        // MuseScore defaults all four title-block styles to
        // `FontStyle::Normal` (no bold, no italic) — see
        // `engraving/style/styledef.cpp`. Per-text overrides via
        // `<Text>` inline markup aren't modelled yet.
        .system(size: size, weight: .regular)
    }

    private static func anchor(
        for anchor: LayoutFrameText.Anchor
    ) -> UnitPoint {
        switch anchor {
        case .topLeading: return .topLeading
        case .top: return .top
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottom: return .bottom
        case .bottomTrailing: return .bottomTrailing
        }
    }
}
