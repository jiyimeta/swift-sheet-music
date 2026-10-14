import SheetMusicFoundation

extension Tempo {
    /// The marking an unauthored tempo prints, in MuseScore's palette spelling (`TempoText::duration2tempoTextString`,
    /// `engraving/dom/tempotext.cpp:173-218`): the beat's metronome glyph — for a dotted beat one `space` and one
    /// `metAugmentationDot` per dot — then " = N".
    package struct MetronomeMarking: Sendable, Equatable {
        /// SMuFL names, as written inside `<sym>`.
        package let symbolNames: [String]
        /// Beats per minute in the printed beat (`Tempo.printedNumber(_:)`).
        package let number: String

        /// The character data after the glyphs: `" = N"`.
        package var trailingText: String {
            " = \(number)"
        }
    }

    /// The derived marking for this tempo's beat and number; `nil` when bps is not a positive finite number.
    ///
    /// Only the beats MuseScore reads back are printed (its `tp` / `tpSym` tables, `tempotext.cpp:113-202`): the six
    /// bases, quarter / half / eighth with up to 2 dots and whole / sixteenth / thirty-second with up to 1. Any other
    /// beat prints as a plain quarter at `bps × 60`, exactly what decoding it falls back to, so encode → decode →
    /// encode is a fixed point.
    package var metronomeMarking: MetronomeMarking? {
        guard beatsPerSecond > 0, beatsPerSecond.isFinite else { return nil }
        let readableDots = 0 ... Self.maxReadableDots(for: beatNote)
        guard let glyph = Self.metronomeGlyphName(for: beatNote), readableDots.contains(beatDots) else {
            return MetronomeMarking(symbolNames: ["metNoteQuarterUp"], number: Self.printedNumber(beatsPerSecond * 60))
        }
        let dots = beatDots > 0 ? ["space"] + Array(repeating: "metAugmentationDot", count: beatDots) : []
        return MetronomeMarking(symbolNames: [glyph] + dots, number: Self.printedNumber(beatsPerMinute))
    }

    /// A tempo as a marking prints it: to two decimals, and without a decimal point when integral. MuseScore stores bps
    /// to six digits, so 40 BPM is `0.666667` and would otherwise print as `40.00002`. A non-finite value prints as
    /// the empty string; a magnitude of 1e15 or more, where an integer spelling no longer fits, prints in `Double`'s
    /// own notation.
    public static func printedNumber(_ beatsPerMinute: Double) -> String {
        guard beatsPerMinute.isFinite else { return "" }
        let printed = (beatsPerMinute * 100).rounded() / 100
        guard printed.isFinite else { return String(beatsPerMinute) }
        return abs(printed) < 1e15 && printed == printed.rounded() ? String(Int(printed)) : String(printed)
    }

    /// The most dots MuseScore's `tp` / `tpSym` tables list after `beat`'s glyph.
    static func maxReadableDots(for beat: NoteDuration) -> Int {
        switch beat {
        case .quarter, .half, .eighth: 2
        default: 1
        }
    }

    /// SMuFL name of the metronome glyph for `beat` — MuseScore's `tpSym` names — or `nil` for a beat `Tempo.decode`
    /// would not recognize on the way back.
    static func metronomeGlyphName(for beat: NoteDuration) -> String? {
        switch beat {
        case .whole: "metNoteWhole"
        case .half: "metNoteHalfUp"
        case .quarter: "metNoteQuarterUp"
        case .eighth: "metNote8thUp"
        case .sixteenth: "metNote16thUp"
        case .thirtySecond: "metNote32ndUp"
        default: nil
        }
    }

    /// The derived marking as runs: its glyphs as symbol runs, then the number as a text run.
    var synthesizedRichText: RichText? {
        metronomeMarking.map { marking in
            RichText(lines: [
                marking.symbolNames.map { RichTextRun.symbol(name: $0, RichTextFormat()) }
                    + [.text(marking.trailingText, RichTextFormat())],
            ])
        }
    }

    /// What the marking prints: its authored runs while the markup is current, its authored plain text, or the derived
    /// marking. Layout draws it; the edit rules read it (`TempoTextEquation`).
    public var displayedRichText: RichText {
        if let richText { return richText }
        if let text {
            return RichText(lines: text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                line.isEmpty ? [] : [.text(String(line), RichTextFormat())]
            })
        }
        return synthesizedRichText ?? RichText(lines: [[]])
    }

    /// Whether `markup` is exactly the derived marking's `<text>` — the glyph elements in order, then `" = N"` — the
    /// shape this library's encoder and MuseScore's palette both write. Such a text decodes as derived (`text == nil`).
    ///
    /// Deliberately strict: older MuseScore files carry `<sym>…</sym><font face="Edwin"/> = N`, and that is NOT
    /// matched. It stays authored (the preserved path), so its font element survives a round trip instead of being
    /// replaced by the palette spelling.
    package func isSynthesizedMarking(_ markup: PreservedTextMarkup) -> Bool {
        guard let marking = metronomeMarking else { return false }
        let glyphs: [PreservedTextMarkup.ContentItem] = marking.symbolNames.map { name in
            .element(PreservedTextMarkup.Element(name: "sym", content: [.characters(name)]))
        }
        return markup.content == glyphs + [.characters(marking.trailingText)]
    }
}
