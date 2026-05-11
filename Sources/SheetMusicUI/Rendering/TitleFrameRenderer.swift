import SheetMusicCore
import SheetMusicLayout
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
        origin: CGPoint = .zero,
    ) {
        for entry in frame.texts {
            drawEntry(entry, into: &context, origin: origin)
        }
    }

    /// Multi-line `<Text>` blocks (e.g. test-platinum.mscx's three
    /// Lyricist lyric columns) need each line drawn at its own y
    /// with the same horizontal anchor — `Canvas.resolve` only takes
    /// a `Text` literal, so SwiftUI's `.multilineTextAlignment` modifier
    /// can't reach it. We split on `\n` and draw line-by-line.
    private static func drawEntry(
        _ entry: LayoutFrameText,
        into context: inout GraphicsContext,
        origin: CGPoint,
    ) {
        let lines = entry.text.split(
            separator: "\n", omittingEmptySubsequences: false,
        ).map(String.init)
        // SwiftUI's `Text` resolves with the system line-height
        // factor (~1.2× point size). Match that so per-line stacking
        // matches what `.multilineTextAlignment` would have produced
        // had we been able to use it directly.
        let lineHeight = entry.fontSize * 1.2
        let pos = CGPoint(
            x: origin.x + entry.position.x,
            y: origin.y + entry.position.y,
        )
        let topY: CGFloat = entry.anchor.isBottom
            ? pos.y - CGFloat(lines.count) * lineHeight
            : pos.y
        let lineAnchor = topAnchor(for: entry.anchor)
        let lineFont = font(for: entry.style, size: entry.fontSize)

        for (idx, line) in lines.enumerated() {
            let resolved = context.resolve(
                Text(line).font(lineFont).foregroundColor(.black),
            )
            context.draw(
                resolved,
                at: CGPoint(
                    x: pos.x,
                    y: topY + CGFloat(idx) * lineHeight,
                ),
                anchor: lineAnchor,
            )
        }
    }

    private static func font(
        for style: FrameText.Style, size: CGFloat,
    ) -> Font {
        // MuseScore defaults all four title-block styles to
        // `FontStyle::Normal` (no bold, no italic) — see
        // `engraving/style/styledef.cpp`. Per-text overrides via
        // `<Text>` inline markup aren't modelled yet.
        .system(size: size, weight: .regular)
    }

    /// SwiftUI anchor for the *top edge* of a single line. Used by
    /// the per-line drawing loop above — the bottom-anchored input
    /// case is handled by shifting the starting `y` upward, not by
    /// flipping the per-line anchor.
    private static func topAnchor(
        for anchor: LayoutFrameText.Anchor,
    ) -> UnitPoint {
        switch anchor {
        case .topLeading, .bottomLeading: .topLeading
        case .top, .bottom: .top
        case .topTrailing, .bottomTrailing: .topTrailing
        }
    }
}

@available(macOS 15.0, iOS 16.0, *)
extension LayoutFrameText.Anchor {
    fileprivate var isBottom: Bool {
        switch self {
        case .bottomLeading, .bottom, .bottomTrailing: true
        case .topLeading, .top, .topTrailing: false
        }
    }
}
