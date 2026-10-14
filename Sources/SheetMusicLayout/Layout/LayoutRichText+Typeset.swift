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
    /// font at the dynamics scale instead (`textbase.cpp:881-905`), so this table's `.dynamics` row is not that size:
    /// formatted dynamics are not typeset yet, and when they are, their symbol size goes to the base initializer
    /// (`symbolPointSize`) rather than coming from here.
    static func musicalSymbolSize(for style: TextStyleType) -> CGFloat {
        switch style {
        case .title: 22
        // `Sid::repeatLeftMusicalSymbolSize` / `repeatRightMusicalSymbolSize` (styledef.cpp:2059, 2061).
        case .repeatLeft, .repeatRight: 18
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
    /// The face MuseScore gives every symbol in a text (`TextBase::createBlocks`,
    /// `engraving/dom/textbase.cpp:1724-1740`) and the one MuseScore 2/3 files spell a metronome mark in: `<font
    /// face="ScoreText"/>` then U+ECA5.
    static let scoreTextFace = "ScoreText"
    /// SMuFL's code points: the Private Use Area.
    static let smuflScalars: ClosedRange<UInt32> = 0xE000 ... 0xF8FF
    /// What `<sym>space</sym>` inserts (`textbase.cpp:1731-1732`).
    static let spaceCodepoint: UInt32 = 0x20

    let baseFont: LayoutFont
    let pointScale: CGFloat
    let symbolPointSize: CGFloat
    let underline: Bool
    let strike: Bool

    /// What a source run typesets as: its content, its format, and whether it can carry an underline or a strike.
    private struct Piece {
        let content: LayoutRichTextRun.Content
        let format: RichTextFormat
        let decorates: Bool
    }

    func line(_ source: [RichTextRun]) -> LayoutRichTextLine {
        let provider = FontMetrics.provider
        var runs: [LayoutRichTextRun] = []
        var pen: CGFloat = 0
        var ascent: CGFloat?
        var descent: CGFloat?
        for piece in source.flatMap(Self.pieces(of:)) {
            let runFont = font(for: piece.content, format: piece.format)
            let advance = provider.typographicWidth(text: piece.content.string, font: runFont)
            runs.append(LayoutRichTextRun(
                content: piece.content, font: runFont, x: pen, advance: advance,
                baselineShift: baselineShift(piece.format, font: runFont),
                underline: piece.decorates && (piece.format.underline ?? underline),
                strike: piece.decorates && (piece.format.strike ?? strike),
            ))
            pen += advance
            if case .text = piece.content {
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

    /// Only a fragment in a text face is underlined or struck through (`TextFragment::font`, `textbase.cpp:914-920`);
    /// every `<sym>`, the `space` one included, is a ScoreText fragment. MuseScore inserts U+0020 for `SymId::space`
    /// and sets the fragment's family to ScoreText, like any symbol, so its advance is the music font's space at the
    /// symbol size, not the text font's; a name it has no glyph for is dropped (`TextBase::createBlocks`,
    /// `textbase.cpp:1724-1740`). The space is therefore a symbol run, measured and drawn in Bravura.
    private static func pieces(of run: RichTextRun) -> [Piece] {
        switch run {
        case let .text(text, format) where format.face == scoreTextFace:
            return scoreTextPieces(text, format: format)
        case let .text(text, format):
            return [Piece(content: .text(text), format: format, decorates: true)]
        case let .symbol(name, format):
            if name == "space" {
                return [Piece(content: .symbol(codepoint: spaceCodepoint), format: format, decorates: false)]
            }
            guard let codepoint = SMuFLCodepoint.byName(name) else { return [] }
            return [Piece(content: .symbol(codepoint: codepoint), format: format, decorates: false)]
        }
    }

    /// A text run in the ScoreText face is music, as MuseScore draws it: each SMuFL character a symbol run, anything
    /// else text in the element's own face (ScoreText has no letters).
    private static func scoreTextPieces(_ text: String, format: RichTextFormat) -> [Piece] {
        var textFormat = format
        textFormat.face = nil
        var pieces: [Piece] = []
        var pending = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            guard smuflScalars.contains(scalar.value) else {
                pending.append(scalar)
                continue
            }
            if !pending.isEmpty {
                pieces.append(Piece(content: .text(String(pending)), format: textFormat, decorates: true))
                pending = String.UnicodeScalarView()
            }
            pieces.append(Piece(content: .symbol(codepoint: scalar.value), format: format, decorates: false))
        }
        if !pending.isEmpty {
            pieces.append(Piece(content: .text(String(pending)), format: textFormat, decorates: true))
        }
        return pieces
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

extension LayoutRichText {
    /// A tempo marking's plain text typeset as the marking draws — its SMuFL characters (`Tempo.beatGlyph`'s, or a
    /// MuseScore 2/3 metronome character) as glyphs, the rest in the tempo font — for a `.textMark(.tempo)` built
    /// without runs. Layout always supplies runs; this keeps a hand-built element measured and drawn alike everywhere.
    /// The element's face, size and style overrides reach the text through `properties` (the typesetter's base font
    /// resolves them; the ScoreText pieces drop only the run-level face, never the base one).
    package static func tempoText(
        _ text: String, properties: TextProperties = TextProperties(), metrics: StaffMetrics,
    ) -> LayoutRichText {
        let face = RichTextFormat(face: RichTextTypesetter.scoreTextFace)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> [RichTextRun] in
            line.isEmpty ? [] : [.text(String(line), face)]
        }
        return LayoutRichText(RichText(lines: lines), style: .tempo, overrides: properties, metrics: metrics)
    }
}
