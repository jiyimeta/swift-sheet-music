import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout

extension LayoutBridge {
    /// Typeset runs as the draw program already says them — no new opcode, no wire change: each text run is a `.text`
    /// in its own face id inside its own `setTextStyle` pair (`TextFontMapping`, exactly as plain text), each symbol a
    /// SMuFL `.glyph`, both at the baseline layout computed; underline and strike-through are stroked lines in the
    /// current color. A face override reaches the wire only as far as `TextFontMapping` can say it.
    static func emitRichRuns(
        _ runs: [LayoutRichTextPositionedRun], decorations: [LayoutRichTextDecoration], into out: inout [DrawCommand],
    ) {
        for run in runs {
            let x = Double(run.baseline.x) * ptToMMScale
            let y = Double(run.baseline.y) * ptToMMScale
            let size = Double(run.font.pointSize) * ptToMMScale
            switch run.content {
            case let .text(text):
                let wire = TextFontMapping.wire(for: run.font)
                withTextStyle(wire.style, into: &out) { out in
                    out.append(.text(text: text, x: x, y: y, size: size, fontId: wire.fontId))
                }
            case let .symbol(codepoint):
                out.append(.glyph(codepoint: codepoint, x: x, y: y, size: size, fontId: .smufl))
            }
        }
        for bar in decorations {
            out.append(.moveTo(x: Double(bar.from.x) * ptToMMScale, y: Double(bar.from.y) * ptToMMScale))
            out.append(.lineTo(x: Double(bar.to.x) * ptToMMScale, y: Double(bar.to.y) * ptToMMScale))
            out.append(.stroke(width: Double(bar.thickness) * ptToMMScale))
        }
    }

    /// A text element's runs placed at `origin` by `anchor`, with the same per-kind anchors the Apple renderers draw
    /// them at (`LayoutRichText.positionedRuns(at:anchor:)`).
    static func emitRichText(
        _ richText: LayoutRichText, origin: TextInkPoint, anchor: TextInkPoint, into out: inout [DrawCommand],
    ) {
        emitRichRuns(
            richText.positionedRuns(at: origin, anchor: anchor),
            decorations: richText.decorations(at: origin, anchor: anchor),
            into: &out,
        )
    }
}
