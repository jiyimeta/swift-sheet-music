#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutRichText {
    /// MuseScore's script scale (`SUBSCRIPT_SIZE`, `engraving/dom/textbase.h:40`).
    static let scriptScale: CGFloat = 0.6
    /// x-height as a share of the em. MuseScore offsets scripts by the font's measured x-height
    /// (`rendering/score/textlayout.cpp:315-346`); no `FontMetricsProvider` measures it.
    static let xHeightEm: CGFloat = 0.48
    /// `SUBSCRIPT_OFFSET` / `SUPERSCRIPT_OFFSET` (`textbase.h:41-42`), in x-heights, Y-down.
    static let subscriptOffset: CGFloat = 0.5
    static let superscriptOffset: CGFloat = -0.9
    /// Underline and strike-through as shares of the run's size: approximations of a face's underline position, which
    /// no provider measures.
    static let underlineOffsetEm: CGFloat = 0.12
    static let strikeOffsetEm: CGFloat = 0.28
    static let decorationThicknessEm: CGFloat = 0.06
    /// MuseScore's musical-symbol size for repeat text — markers and jumps (`repeatLeftMusicalSymbolSize`,
    /// `repeatRightMusicalSymbolSize`, `engraving/style/styledef.cpp:2059, 2061`).
    static let repeatTextSymbolSize: CGFloat = 18

    /// Typesets `richText` the way MuseScore lays a text element's fragments out (`TextLayout::layoutTextBlock`,
    /// `rendering/score/textlayout.cpp:300-389`): runs left to right from the line's start, each in the element's font
    /// with its own format applied, and lines stacked by their tallest text run.
    ///
    /// - Parameters:
    ///   - baseFont: the element's resolved text font, as the provider draws it (`renderingTextFont`).
    ///   - pointScale: what turns a `<font size="…"/>` into points — the spatium scaling of a spatium-dependent style
    ///     (`sp / 5`), 1 for one that is not (`TextFragment::font`, `engraving/dom/textbase.cpp:859-905`).
    ///   - symbolPointSize: Bravura's size for `<sym>` runs, already scaled.
    ///   - underline, strike: the style's own decorations, which a text run keeps unless its markup set one. A symbol
    ///     run never has one.
    init(
        _ richText: RichText, baseFont: LayoutFont, pointScale: CGFloat, symbolPointSize: CGFloat,
        underline: Bool = false, strike: Bool = false,
    ) {
        let typesetter = RichTextTypesetter(
            baseFont: baseFont, pointScale: pointScale, symbolPointSize: symbolPointSize,
            underline: underline, strike: strike,
        )
        self.init(
            lines: richText.lines.map { typesetter.line($0) },
            leading: FontMetrics.provider.leading(font: baseFont),
        )
    }

    /// `richText` as a text element of `style` with the element's font override — in the font
    /// `TextInkGeometry.font(for:overrides:metrics:)` resolves, which plain text of the same element is measured and
    /// drawn in.
    init(
        _ richText: RichText, style: TextStyleType, overrides: TextProperties = TextProperties(), metrics: StaffMetrics,
    ) {
        let resolved = overrides.resolved(against: style)
        let pointScale = resolved.spatiumDependent ? metrics.sp / TextRoleStyle.referenceSpatiumInPoints : 1
        self.init(
            richText,
            baseFont: TextInkGeometry.font(for: style, overrides: overrides, metrics: metrics),
            pointScale: pointScale,
            symbolPointSize: Self.musicalSymbolSize(for: style) * pointScale,
            underline: resolved.style.contains(.underline),
            strike: resolved.style.contains(.strike),
        )
    }

    /// `richText` as a navigation label (`NotationTextStyle`) — a marker's or a jump's.
    init(_ richText: RichText, role: NotationTextStyle.Role, metrics: StaffMetrics) {
        let pointScale = metrics.sp / TextRoleStyle.referenceSpatiumInPoints
        self.init(
            richText,
            baseFont: NotationTextStyle.font(for: role, sp: metrics.sp),
            pointScale: pointScale,
            symbolPointSize: Self.repeatTextSymbolSize * pointScale,
        )
    }

    /// MuseScore's musical-symbol size for a style's `<sym>` runs, in points at the reference spatium
    /// (`Sid::*MusicalSymbolSize`, `engraving/style/styledef.cpp:2019-2076`). Dynamics draw their symbols in the music
    /// font at the dynamics scale instead (`textbase.cpp:881-905`); W4 passes that size to the base initializer.
    static func musicalSymbolSize(for style: TextStyleType) -> CGFloat {
        switch style {
        case .title: 22
        case .tempo: 20
        case .subtitle, .rehearsalMark: 14
        case .chordSymbolRomanNumeral: 12
        case .pageNumber: 11
        case .header, .footer: 9
        case .glissando, .bend: 8
        case .composer, .lyricist, .lyricsOdd, .lyricsEven, .dynamics, .staffText, .systemText,
             .instrumentChange, .pedal, .chordSymbolA, .chordSymbolB:
            10
        }
    }
}

/// One element's run formatting: the base font and sizes each run's format applies to.
private struct RichTextTypesetter {
    let baseFont: LayoutFont
    let pointScale: CGFloat
    let symbolPointSize: CGFloat
    let underline: Bool
    let strike: Bool

    func line(_ source: [RichTextRun]) -> LayoutRichTextLine {
        let provider = FontMetrics.provider
        var runs: [LayoutRichTextRun] = []
        var pen: CGFloat = 0
        var ascent: CGFloat?
        var descent: CGFloat?
        for run in source {
            let format: RichTextFormat
            let content: LayoutRichTextRun.Content
            // Only a fragment in a text face is underlined or struck through (`TextFragment::font`,
            // `textbase.cpp:914-920`); every `<sym>`, the `space` one included, is a ScoreText fragment.
            let decorates: Bool
            switch run {
            case let .text(text, runFormat):
                format = runFormat
                content = .text(text)
                decorates = true
            case let .symbol(name, runFormat):
                format = runFormat
                decorates = false
                // MuseScore inserts a plain space for `SymId::space`, as ScoreText like any symbol, and drops a name it
                // has no glyph for (`TextBase::createBlocks`, `engraving/dom/textbase.cpp:1724-1740`).
                if name == "space" {
                    content = .text(" ")
                } else if let codepoint = SMuFLCodepoint.byName(name) {
                    content = .symbol(codepoint: codepoint)
                } else {
                    continue
                }
            }
            let runFont = font(for: content, format: format)
            let advance = provider.typographicWidth(text: content.string, font: runFont)
            runs.append(LayoutRichTextRun(
                content: content, font: runFont, x: pen, advance: advance,
                baselineShift: baselineShift(format, font: runFont),
                underline: decorates && (format.underline ?? underline),
                strike: decorates && (format.strike ?? strike),
            ))
            pen += advance
            if case .text = content {
                ascent = max(ascent ?? 0, provider.ascent(font: runFont))
                descent = max(descent ?? 0, provider.descent(font: runFont))
            }
        }
        return LayoutRichTextLine(
            runs: runs, width: pen,
            ascent: ascent ?? provider.ascent(font: baseFont),
            descent: descent ?? provider.descent(font: baseFont),
        )
    }

    /// A symbol is a glyph in the music font, never bold or italic (MuseScore's `musicalSymbolsNotBold` test,
    /// `engraving/tests/textbase_tests.cpp:209-218`), and not script-scaled either: `TextFragment::font` replaces the
    /// size outright for a symbol (`textbase.cpp:887, 902`). Text takes the element's font with the run's format
    /// applied, as the provider can draw it.
    private func font(for content: LayoutRichTextRun.Content, format: RichTextFormat) -> LayoutFont {
        if case .symbol = content {
            return LayoutFont(face: SMuFLFamily.bravura, pointSize: symbolPointSize)
        }
        let script: CGFloat = format.verticalAlign == .normal ? 1 : LayoutRichText.scriptScale
        let size = format.size.map { CGFloat($0) * pointScale } ?? baseFont.pointSize
        return FontMetrics.provider.renderingTextFont(LayoutFont(
            face: format.face ?? baseFont.face,
            pointSize: size * script,
            weight: format.bold.map { $0 ? FontWeight.bold : .regular } ?? baseFont.weight,
            isItalic: format.italic ?? baseFont.isItalic,
        ))
    }

    private func baselineShift(_ format: RichTextFormat, font: LayoutFont) -> CGFloat {
        let xHeight = font.pointSize / LayoutRichText.scriptScale * LayoutRichText.xHeightEm
        return switch format.verticalAlign {
        case .normal: 0
        case .subScript: xHeight * LayoutRichText.subscriptOffset
        case .superScript: xHeight * LayoutRichText.superscriptOffset
        }
    }
}
