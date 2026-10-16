import SheetMusicCore
import SheetMusicFoundation
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
///
/// Each line is measured in the face the layout sets the title block in
/// (`LayoutTitleFrame.font(size:)`, which the Apple renderers draw), as the
/// provider resolves it, and its `.text` names that face (`TextFontMapping`).
extension LayoutBridge {
    /// Emits `frame`'s texts. `originY` (document points) is added to every text's y: 0 for the title block, whose
    /// texts are in document coordinates, and a box's top for a box after it (`LayoutFrame.content`), whose texts are
    /// frame-local in y. `Double`, not `CGFloat`: off Apple this file's `CGFloat` is a private alias an internal
    /// signature cannot name.
    static func appendTitleFrame(
        _ frame: LayoutTitleFrame,
        originY: Double = 0,
        into out: inout [DrawCommand],
    ) {
        // Only a rich entry needs layout's placement; a plain one keeps its own byte-identical stacking below.
        let placed = frame.texts.contains { $0.richText != nil }
            ? frame.placedLines(origin: CGPoint(x: 0, y: CGFloat(originY)))
            : []
        for (index, entry) in frame.texts.enumerated() {
            guard entry.richText != nil else {
                appendTitleEntry(entry, originY: originY, into: &out)
                continue
            }
            // A rich entry draws the runs layout placed per line (`LayoutTitleFrame.PlacedLine.positionedRuns`), so
            // a `<font size>` line steps further exactly as it does in the Apple renderers.
            for line in placed where line.entryIndex == index {
                emitRichRuns(line.positionedRuns, decorations: line.decorations, into: &out)
            }
        }
    }

    /// Emit one `LayoutFrameText`. Multi-line `<Text>` blocks (e.g. a three-line
    /// lyricist credit) are split on `\n` and stacked at `fontSize * 1.2`
    /// per line, matching `LayoutTitleFrame.placedLines` — SwiftUI's `Text`
    /// resolves with the same ~1.2× system line-height factor.
    private static func appendTitleEntry(
        _ entry: LayoutFrameText,
        originY: Double,
        into out: inout [DrawCommand],
    ) {
        // The face the layout sets the title block in — the system face the Apple renderers draw — as this provider
        // can measure it: the system face itself on the Apple and Windows providers, Edwin regular where a table
        // provider normalizes it (Android, the web — the stream they read before v8, byte for byte). Width and ascent
        // below are measured in this font, and the face id and style bits name it (`TextFontMapping`), so a reader
        // draws each line in the face it was anchored with. `fontSize` is already resolved per style by the layout
        // engine, so the style itself needs no remapping.
        let fontSize = Double(entry.fontSize)
        let font = FontMetrics.provider.renderingTextFont(LayoutTitleFrame.font(size: entry.fontSize))
        let wire = TextFontMapping.wire(for: font)
        let ascent = Double(FontMetrics.provider.ascent(font: font))

        let lines = entry.text.split(
            separator: "\n", omittingEmptySubsequences: false,
        ).map(String.init)
        let lineHeight = fontSize * 1.2
        let posX = Double(entry.position.x)
        let posY = originY + Double(entry.position.y)
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
            withTextStyle(wire.style, into: &out) { out in
                out.append(.text(
                    text: line,
                    x: (posX + anchorDx) * ptToMMScale,
                    y: baselineY * ptToMMScale,
                    size: fontSize * ptToMMScale,
                    fontId: wire.fontId,
                ))
            }
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
