import Foundation
import SheetMusicCore
import SheetMusicLayout

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// Title-block (leading `<VBox>`) rendering for the Android draw-command
/// bridge. Mirrors the Apple renderer's `TitleFrameView` / `TitleFrameRenderer`:
/// the resolved `LayoutTitleFrame` sits at the document's top-leading corner
/// (y = 0 … `frame.height`) and the systems below it were already shifted down
/// by that height in `LayoutEngine`. Before this was added the bridge walked
/// only systems, so the whole title block — title, subtitle, composer,
/// lyricist — was silently dropped and Android showed a blank gap at the top.
///
/// The Apple side draws each entry with SwiftUI's anchored
/// `GraphicsContext.draw(_:at:anchor:)`. Android's `.text` opcode anchors at
/// the baseline-leading corner, so anchoring is resolved here on the Swift
/// side via `FontMetrics.provider` (advance width + ascent), the same approach
/// every other label emitter in this bridge uses (`encodeNotationText`, …).
extension LayoutBridge {
    static func appendTitleFrame(
        _ frame: LayoutTitleFrame,
        into out: inout [DrawCommand],
    ) {
        for entry in frame.texts {
            appendTitleEntry(entry, into: &out)
        }
    }

    /// Emit one `LayoutFrameText`. Multi-line `<Text>` blocks (e.g. a three-line
    /// lyricist credit) are split on `\n` and stacked at `fontSize * 1.2`
    /// per line, matching `TitleFrameRenderer.drawEntry` — SwiftUI's `Text`
    /// resolves with the same ~1.2× system line-height factor.
    private static func appendTitleEntry(
        _ entry: LayoutFrameText,
        into out: inout [DrawCommand],
    ) {
        // Apple draws title-block text in the system font; Android's draw
        // program only carries the Edwin (text-roman) and Bravura (SMuFL)
        // faces, so title text engraves in Edwin — the same face MuseScore
        // defaults the title styles to. `fontSize` is already resolved per
        // style by the layout engine, so the style itself needs no remapping.
        let fontSize = Double(entry.fontSize)
        let font = LayoutFont(face: "Edwin", pointSize: entry.fontSize)
        let ascent = Double(FontMetrics.provider.ascent(font: font))

        let lines = entry.text.split(
            separator: "\n", omittingEmptySubsequences: false,
        ).map(String.init)
        let lineHeight = fontSize * 1.2
        let posX = Double(entry.position.x)
        let posY = Double(entry.position.y)
        // A bottom-anchored entry positions its block so the LAST line's
        // bottom lands on `position.y`; shift the first line's top up by the
        // full block height (mirrors `TitleFrameRenderer`).
        let topY = entry.anchor.isBottom
            ? posY - Double(lines.count) * lineHeight
            : posY

        for (idx, line) in lines.enumerated() where !line.isEmpty {
            let width = Double(FontMetrics.provider.typographicWidth(
                text: line, font: font,
            ))
            // SwiftUI's `.topLeading` / `.top` / `.topTrailing` per-line anchor
            // pins the line's top edge; convert the horizontal anchor to a
            // left-edge offset and the top edge to a baseline (top + ascent),
            // matching this bridge's frame model where a glyph row spans
            // [baseline − ascent, baseline + descent].
            let anchorDx: Double = switch entry.anchor.horizontal {
            case .leading: 0
            case .center: -width / 2
            case .trailing: -width
            }
            let lineTopY = topY + Double(idx) * lineHeight
            let baselineY = lineTopY + ascent
            out.append(.text(
                text: line,
                x: (posX + anchorDx) * ptToMMScale,
                y: baselineY * ptToMMScale,
                size: fontSize * ptToMMScale,
                fontId: .textRoman,
            ))
        }
    }
}

extension LayoutFrameText.Anchor {
    fileprivate enum Horizontal { case leading, center, trailing }

    fileprivate var horizontal: Horizontal {
        switch self {
        case .topLeading, .bottomLeading: .leading
        case .top, .bottom: .center
        case .topTrailing, .bottomTrailing: .trailing
        }
    }

    fileprivate var isBottom: Bool {
        switch self {
        case .bottomLeading, .bottom, .bottomTrailing: true
        case .topLeading, .top, .topTrailing: false
        }
    }
}
