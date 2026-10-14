import SheetMusicFoundation

/// Locating a marking's "beat = number" in its words, for `Tempo.applyNumberEdit`.
///
/// The classifier (`TempoTextEquation`) picks the first pattern in MuseScore's table order that has a "beat = number"
/// anywhere, and within it the first such equation in document order. Every locator here is handed that pattern's
/// beat length and takes the first equation of that beat in document order, which is the same equation — except where
/// the classifier's equation cannot be reached in the markup (below), when the markup is left alone.
///
/// The classifier removes "ca." / "c." / "approx." before it reads, so they may stand anywhere in the equation; the
/// locators skip them with the same function (`skippingSpacesAndPrefixes`) wherever the classifier would have them
/// removed, and leave them in the text. A plain text the classifier accepts is therefore always located, with one
/// exception: a glyph written as `<sym>`s that a text run splits ("♩", a typed space, then a dot symbol) reads as one
/// beat to the classifier, but as separate runs here.
extension Tempo {
    /// Where an equation sits in a plain text: its beat glyph (empty for a glyph written as `<sym>`s, which plain text
    /// drops — it is then the position the glyph would stand at) and its number.
    struct EquationMatch {
        let glyph: Range<String.Index>
        let number: Range<String.Index>
    }

    /// The equation `TempoTextEquation` matched, in the plain `text` that `reading` (the marking's runs) flattens
    /// to: the first of beat `quarters`, whether its glyph is a metronome codepoint in the text or a symbol run in
    /// `reading`.
    static func equationMatch(in text: String, reading: RichText, quarters: Double) -> EquationMatch? {
        let inText = equationSpans(in: text, quarters: quarters)
        let inSymbols = symbolEquation(in: reading, text: text, quarters: quarters)
        guard let inText else { return inSymbols }
        guard let inSymbols else { return inText }
        return inText.glyph.lowerBound <= inSymbols.glyph.lowerBound ? inText : inSymbols
    }

    /// `text` with `match` rewritten: its number replaced by `number`, and its glyph by `glyphs` (SMuFL names) when
    /// given and the glyph is in the text.
    static func spliced(_ text: String, _ match: EquationMatch, glyphs: [String]?, number: String) -> String {
        let scalars = text.unicodeScalars
        let glyph = match.glyph.isEmpty ? "" : (glyphs.map(glyphString) ?? String(scalars[match.glyph]))
        return String(scalars[..<match.glyph.lowerBound]) + glyph
            + String(scalars[match.glyph.upperBound ..< match.number.lowerBound]) + number
            + String(scalars[match.number.upperBound...])
    }

    /// `text` with the equation of beat `quarters` whose glyph is written in it as metronome codepoints
    /// (U+ECA0–U+ECB7) rewritten (`spliced`); `nil` when the text holds none. Anchoring on the glyph is what keeps
    /// "2 Allegro ♩ = 120" and "x = 3 ♩ = 120" from rewriting the wrong number.
    static func rewrittenEquation(in text: String, glyphs: [String]?, number: String, quarters: Double) -> String? {
        equationSpans(in: text, quarters: quarters).map { spliced(text, $0, glyphs: glyphs, number: number) }
    }

    /// The length in quarters of the beat the metronome symbols `names` spell (a note, then its dots), or `nil` when
    /// they spell none `TempoTextEquation` reads.
    static func beatQuarters(ofSymbols names: [String]) -> Double? {
        let notes = names.compactMap { TempoTextEquation.metronomeCodepoints[$0] }
        guard let note = notes.first(where: { $0 != TempoTextEquation.dot }) else { return nil }
        return beatQuarters(note: note, dots: names.filter { $0 == "metAugmentationDot" }.count)
    }

    static func beatQuarters(note: Unicode.Scalar, dots: Int) -> Double? {
        TempoTextEquation.patterns.first { $0.note == note && $0.dots == dots }?.quarters
    }

    /// A `<sym>` name of the metronome range (or the `space` between a note and its dots) — what the classifier reads.
    static func isMetronomeSymbolName(_ name: String) -> Bool {
        name == "space" || TempoTextEquation.metronomeCodepoints[name] != nil
    }

    // MARK: Glyphs written as codepoints in the text

    /// The beat glyph written as `names` (SMuFL metronome names, `space` as a space) in codepoints.
    static func glyphString(_ names: [String]) -> String {
        var result = String.UnicodeScalarView()
        for name in names {
            if name == "space" {
                result.append(" ")
            } else if let codepoint = TempoTextEquation.metronomeCodepoints[name] {
                result.append(codepoint)
            }
        }
        return String(result)
    }

    /// The first "glyph = number" of beat `quarters` in `text`: a metronome note, up to two dots after it, an equals
    /// sign, the number.
    private static func equationSpans(in text: String, quarters: Double) -> EquationMatch? {
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            defer { index = scalars.index(after: index) }
            guard TempoTextEquation.patterns.contains(where: { $0.note == scalars[index] }) else { continue }
            var glyphEnd = scalars.index(after: index)
            var dots = 0
            while dots < 2 {
                let probe = skippingSpacesAndPrefixes(from: glyphEnd, in: text)
                guard probe < scalars.endIndex, scalars[probe] == TempoTextEquation.dot else { break }
                glyphEnd = scalars.index(after: probe)
                dots += 1
            }
            guard let length = beatQuarters(note: scalars[index], dots: dots), abs(length - quarters) < 1e-9
            else { continue }
            let sign = skippingSpacesAndPrefixes(from: glyphEnd, in: text)
            if sign < scalars.endIndex, isSign(scalars[sign]), let number = numberAfter(sign, in: text) {
                return EquationMatch(glyph: index ..< glyphEnd, number: number)
            }
        }
        return nil
    }

    // MARK: Glyphs written as symbols

    /// The first "symbols = number" of beat `quarters` in `reading`, located in the plain `text` it flattens to: a run
    /// of metronome symbols has no width there, so the equation is whatever follows the text before it.
    private static func symbolEquation(in reading: RichText, text: String, quarters: Double) -> EquationMatch? {
        let scalars = text.unicodeScalars
        var offset = 0
        for (lineIndex, line) in reading.lines.enumerated() {
            if lineIndex > 0 { offset += 1 }
            var run = 0
            while run < line.count {
                if case let .text(string, _) = line[run] {
                    offset += string.unicodeScalars.count
                    run += 1
                    continue
                }
                var names: [String] = []
                while run < line.count, case let .symbol(name, _) = line[run], isMetronomeSymbolName(name) {
                    names.append(name)
                    run += 1
                }
                guard !names.isEmpty else {
                    run += 1
                    continue
                }
                guard let length = beatQuarters(ofSymbols: names), abs(length - quarters) < 1e-9,
                      let start = scalars.index(scalars.startIndex, offsetBy: offset, limitedBy: scalars.endIndex)
                else { continue }
                let sign = skippingSpacesAndPrefixes(from: start, in: text)
                if sign < scalars.endIndex, isSign(scalars[sign]), let number = numberAfter(sign, in: text) {
                    return EquationMatch(glyph: start ..< start, number: number)
                }
            }
        }
        return nil
    }

    // MARK: Numbers

    /// What a character run of a markup holds of an equation that continues from the previous run
    /// (`PreservedTextMarkup.replacingEquation`).
    enum EquationLeaf {
        /// Only whitespace: the equation continues in the next run.
        case blank
        /// An equals sign with nothing after it: the number is in the next run.
        case signOnly
        /// The number, in this run.
        case number(Range<String.Index>)
        /// Something else: the equation does not continue here.
        case unrelated
    }

    /// Reads a character run that follows a metronome glyph (`afterSign` false) or an equals sign (`afterSign` true).
    static func readEquationLeaf(_ text: String, afterSign: Bool) -> EquationLeaf {
        if afterSign {
            if let number = numberStarting(at: text.startIndex, in: text) { return .number(number) }
            return skippingSpacesAndPrefixes(from: text.startIndex, in: text) == text.endIndex ? .blank : .unrelated
        }
        let sign = skippingSpacesAndPrefixes(from: text.startIndex, in: text)
        guard sign < text.endIndex else { return .blank }
        guard isSign(of: text[sign]) else { return .unrelated }
        if let number = numberAfter(sign, in: text) { return .number(number) }
        return skippingSpacesAndPrefixes(from: text.index(after: sign), in: text) == text.endIndex
            ? .signOnly : .unrelated
    }

    /// The equals signs MuseScore reads: =, ≒, ≈, ~.
    private static func isSign(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "=", "≒", "≈", "~": true
        default: false
        }
    }

    private static func isSign(of character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return false }
        return isSign(scalar)
    }

    static func isDigit(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return false }
        return TempoTextEquation.isDigit(scalar)
    }

    private static func numberAfter(_ sign: String.Index, in text: String) -> Range<String.Index>? {
        numberStarting(at: text.index(after: sign), in: text)
    }

    /// Past whitespace and MuseScore's "ca." / "c." / "approx." prefixes.
    private static func skippingSpacesAndPrefixes(from start: String.Index, in text: String) -> String.Index {
        var cursor = start
        var skipping = true
        while skipping {
            while cursor < text.endIndex, text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            if let prefix = ["approx.", "ca.", "c."].first(where: { text[cursor...].hasPrefix($0) }) {
                cursor = text.index(cursor, offsetBy: prefix.count)
            } else {
                skipping = false
            }
        }
        return cursor
    }

    /// The digits at `start` (past spaces and prefixes), with at most one decimal point or comma inside them.
    static func numberStarting(at start: String.Index, in text: String) -> Range<String.Index>? {
        var cursor = skippingSpacesAndPrefixes(from: start, in: text)
        let first = cursor
        var end = cursor
        var separatorSeen = false
        while cursor < text.endIndex {
            let character = text[cursor]
            if isDigit(character) {
                cursor = text.index(after: cursor)
                end = cursor
            } else if character == "." || character == ",", !separatorSeen, end > first {
                separatorSeen = true
                cursor = text.index(after: cursor)
            } else {
                break
            }
        }
        return end > first ? first ..< end : nil
    }
}
