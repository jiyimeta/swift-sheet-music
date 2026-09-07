import CoreText
import SheetMusicCore
import SheetMusicLayout
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Draws the texts of a `LayoutTitleFrame` (resolved positions +
/// font sizes) into a `GraphicsContext`. Used by the PDF exporter,
/// which draws into a resolution-independent context and so has
/// nothing to gain from a layer tree.
///
/// The on-screen title block does NOT come through here any more —
/// it is `TitleFrameView`'s CALayer tree, so that it stays sharp
/// when the reader zooms. What the two share is `placedLines`
/// below: every decision about WHERE a line goes is made once, so
/// the screen and the PDF cannot drift apart.
@available(macOS 15.0, *)
public enum TitleFrameRenderer {
    public static func draw(
        _ frame: LayoutTitleFrame,
        into context: inout GraphicsContext,
        origin: CGPoint = .zero,
    ) {
        for line in placedLines(frame, origin: origin) {
            let resolved = context.resolve(
                Text(line.text)
                    .font(font(size: line.fontSize))
                    .foregroundColor(.black),
            )
            context.draw(
                resolved, at: line.position, anchor: line.anchor,
            )
        }
    }

    // MARK: - Placement (shared with the layer renderer)

    /// One line of a `LayoutFrameText`, already placed: the string,
    /// the point its anchor lands on, and which corner of the line
    /// that anchor names.
    ///
    /// The anchor is always a TOP one. A bottom-anchored block is
    /// expressed by shifting the first line's `y` up by the block
    /// height instead, so a caller only ever has to honour three
    /// horizontal alignments.
    struct PlacedLine {
        let text: String
        let position: CGPoint
        let anchor: UnitPoint
        let fontSize: CGFloat
    }

    /// Multi-line `<Text>` blocks (e.g. test-platinum.mscx's three
    /// Lyricist lyric columns) need each line placed at its own y
    /// with the same horizontal anchor — `Canvas.resolve` only takes
    /// a `Text` literal, so SwiftUI's `.multilineTextAlignment`
    /// modifier can't reach it. We split on `\n` and place
    /// line-by-line.
    static func placedLines(
        _ frame: LayoutTitleFrame, origin: CGPoint = .zero,
    ) -> [PlacedLine] {
        frame.texts.flatMap { placedLines(of: $0, origin: origin) }
    }

    private static func placedLines(
        of entry: LayoutFrameText, origin: CGPoint,
    ) -> [PlacedLine] {
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

        return lines.enumerated().map { idx, line in
            PlacedLine(
                text: line,
                position: CGPoint(
                    x: pos.x,
                    y: topY + CGFloat(idx) * lineHeight,
                ),
                anchor: lineAnchor,
                fontSize: entry.fontSize,
            )
        }
    }

    // MARK: - Face

    // MuseScore defaults all four title-block styles to
    // `FontStyle::Normal` (no bold, no italic) — see
    // `engraving/style/styledef.cpp`. Per-text overrides via
    // `<Text>` inline markup aren't modelled yet.

    private static func font(size: CGFloat) -> Font {
        .system(size: size, weight: .regular)
    }

    /// The same face as `font(size:)`, for the CoreText side.
    /// `Font.system(size:weight:)` resolves to exactly this — the
    /// two have to agree or the screen and the PDF would set the
    /// title in different type.
    static func ctFont(size: CGFloat) -> CTFont {
        #if os(macOS)
            return NSFont.systemFont(
                ofSize: size, weight: .regular,
            ) as CTFont
        #else
            return UIFont.systemFont(
                ofSize: size, weight: .regular,
            ) as CTFont
        #endif
    }

    /// SwiftUI anchor for the *top edge* of a single line. Used by
    /// the per-line placement above — the bottom-anchored input
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

@available(macOS 15.0, *)
extension LayoutFrameText.Anchor {
    fileprivate var isBottom: Bool {
        switch self {
        case .bottomLeading, .bottom, .bottomTrailing: true
        case .topLeading, .top, .topTrailing: false
        }
    }
}
