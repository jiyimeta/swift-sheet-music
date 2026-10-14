#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutRichText {
    /// A marker's text in its repeat style, every symbol in it set on half the cap height of the text beside it —
    /// MuseScore's `TextLayout::musicSymbolBaseLineAdjust` (`rendering/score/textlayout.cpp:391-414`), which it applies
    /// to markers alone: a segno or coda sits centered on the capitals of "To" rather than standing on the baseline.
    /// With no text beside it the marker's own font is the reference, so a lone segno sits where it would beside a
    /// capital. Cap height is measured as the ink top of "H": no `FontMetricsProvider` reports it.
    init(marker richText: RichText, style: TextStyleType, metrics: StaffMetrics) {
        let typeset = LayoutRichText(richText, style: style, metrics: metrics)
        let baseFont = TextInkGeometry.font(for: style, metrics: metrics)
        self.init(
            lines: typeset.lines.map { Self.centeringSymbols(in: $0, baseFont: baseFont) },
            leading: typeset.leading,
        )
    }

    private static func centeringSymbols(in line: LayoutRichTextLine, baseFont: LayoutFont) -> LayoutRichTextLine {
        let provider = FontMetrics.provider
        let runs = line.runs.indices.map { index -> LayoutRichTextRun in
            let run = line.runs[index]
            let reference = referenceFont(at: index, in: line.runs) ?? baseFont
            guard case .symbol = run.content,
                  let symbol = provider.textInkBounds(text: run.content.string, font: run.font),
                  let capital = provider.textInkBounds(text: "H", font: reference)
            else { return run }
            // Y-down: the symbol's ink center lands half the cap height above the line's baseline.
            return LayoutRichTextRun(
                content: run.content, font: run.font, x: run.x, advance: run.advance,
                baselineShift: symbol.midY - capital.maxY / 2, underline: run.underline, strike: run.strike,
            )
        }
        return LayoutRichTextLine(runs: runs, width: line.width, ascent: line.ascent, descent: line.descent)
    }

    /// MuseScore's reference fragment — the one before the symbol, else the one after — read here as the nearest text
    /// run, since consecutive symbols are one fragment there.
    private static func referenceFont(at index: Int, in runs: [LayoutRichTextRun]) -> LayoutFont? {
        let before = runs[..<index].last { if case .text = $0.content { true } else { false } }
        let after = runs[(index + 1)...].first { if case .text = $0.content { true } else { false } }
        return (before ?? after)?.font
    }

    /// The glyphs `Marker::symbolString` looks for, in its order (`engraving/dom/marker.cpp:245-265`) — the ones the
    /// bundled Bravura table names; MuseScore's `codaJapanes` (sic) and `segnoJapanese` resolve to nothing here.
    static let repeatSymbols: [UInt32] = ["coda", "codaSquare", "segno", "segnoSerpent1", "segnoSerpent2"]
        .compactMap { SMuFLCodepoint.byName($0) }

    /// Where, from the block's left ink edge, a marker holding a segno or coda puts the barline — `nil` for one holding
    /// none of `repeatSymbols`, which MuseScore aligns by its own edge instead.
    ///
    /// MuseScore centers such a marker on the barline (`centerOnSymbol`, `MarkerLayout::doLayoutMarker`), then moves it
    /// so that the symbol's own fragment is the centered one (`computeCustomTextOffset`): the first fragment holding
    /// exactly the first of `repeatSymbols` the text contains. Consecutive symbols share a fragment there, so a
    /// codetta's two codas match nothing and stay centered as a pair. `anchor` is the one the element is drawn at; it
    /// decides how a shorter line sits under a longer one.
    func repeatSymbolX(anchor: CGPoint) -> CGFloat? {
        let symbols = lines.flatMap(\.runs).compactMap { run -> UInt32? in
            if case let .symbol(codepoint) = run.content { codepoint } else { nil }
        }
        guard let reference = Self.repeatSymbols.first(where: { symbols.contains($0) }) else { return nil }
        let width = ink?.width ?? 0
        let placed = positionedRuns(at: CGPoint(x: anchor.x * width, y: anchor.y * size.height), anchor: anchor)
        var index = 0
        for line in lines {
            for position in line.runs.indices {
                defer { index += 1 }
                guard case let .symbol(codepoint) = line.runs[position].content, codepoint == reference,
                      Self.standsAlone(position, in: line.runs),
                      let ink = FontMetrics.provider.textInkBounds(
                          text: placed[index].content.string, font: placed[index].font,
                      )
                else { continue }
                return placed[index].baseline.x + ink.midX
            }
        }
        return width / 2
    }

    private static func standsAlone(_ position: Int, in runs: [LayoutRichTextRun]) -> Bool {
        func isSymbol(_ index: Int) -> Bool {
            guard runs.indices.contains(index) else { return false }
            if case .symbol = runs[index].content { return true }
            return false
        }
        return !isSymbol(position - 1) && !isSymbol(position + 1)
    }
}
