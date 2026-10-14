import CoreText
import SheetMusicCore
import SheetMusicLayout
import SheetMusicLayoutApple
import SwiftUI

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
///
/// A formatted line (one with `richRuns`) is drawn as filled glyph outlines, not as `Text`, so in an exported PDF
/// it is not searchable or selectable text, unlike a plain line. Recorded, not fixed.
@available(macOS 15.0, *)
public enum TitleFrameRenderer {
    public static func draw(
        _ frame: LayoutTitleFrame,
        into context: inout GraphicsContext,
        origin: CGPoint = .zero,
    ) {
        for line in placedLines(frame, origin: origin) {
            if !line.richRuns.isEmpty {
                if let path = ScoreLayerBuilder.richTextPath(runs: line.richRuns, decorations: line.richDecorations) {
                    context.fill(Path(path), with: .color(.black))
                }
                continue
            }
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
        /// The rich line's runs on the page; empty for a plain line (`LayoutTitleFrame.PlacedLine.positionedRuns`).
        let richRuns: [LayoutRichTextPositionedRun]
        let richDecorations: [LayoutRichTextDecoration]
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
                richRuns: line.positionedRuns, richDecorations: line.decorations,
            )
        }
    }

    // MARK: - Face

    // A plain line's face is `LayoutTitleFrame.font(size:)` — the system face, regular, MuseScore's
    // `FontStyle::Normal` for all four title-block styles. A line with inline markup (`<b>`, `<font size>`, `<sym>`)
    // is drawn from its typeset runs instead (`richRuns`), each in the font layout set it in.

    /// `ctFont(size:)` as a SwiftUI font, so the PDF sets the title in
    /// the very `CTFont` the screen's layer tree draws.
    private static func font(size: CGFloat) -> Font {
        Font(ctFont(size: size))
    }

    /// The title block's face at `size`, as CoreText resolves it —
    /// `LayoutTitleFrame.font(size:)`, the font the draw-program
    /// bridge measures and names a title line with, so the Apple
    /// screen, the PDF and a reader of the draw program set the title
    /// in the same type.
    static func ctFont(size: CGFloat) -> CTFont {
        AppleFontMetricsProvider().renderingFont(
            for: LayoutTitleFrame.font(size: size),
        )
    }
}
