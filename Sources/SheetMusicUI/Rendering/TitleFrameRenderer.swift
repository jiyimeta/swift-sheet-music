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

    /// `LayoutTitleFrame.placedLines(origin:)` in SwiftUI's anchor
    /// vocabulary. The placement itself lives in SheetMusicLayout so a
    /// host placing an inline editor over a credit reads the same
    /// answer the renderers draw from.
    static func placedLines(
        _ frame: LayoutTitleFrame, origin: CGPoint = .zero,
    ) -> [PlacedLine] {
        frame.placedLines(origin: origin).map { line in
            PlacedLine(
                text: line.text,
                position: line.position,
                anchor: UnitPoint(x: line.horizontalAnchor, y: 0),
                fontSize: line.fontSize,
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
}
