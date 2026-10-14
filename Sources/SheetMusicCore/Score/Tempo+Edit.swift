import SheetMusicFoundation

extension Tempo {
    /// Writes `marking` (`SetTempo`): the number and beat, `<play>` when it says, and the text as its `TextEdit` says —
    /// `.keep` leaving the words to the number-edit rule when the number or the beat moved (`applyNumberEdit`).
    ///
    /// `reported` is what `SetTempo.current` handed the host for this beat — the number and beat the marking is being
    /// compared with. It differs from the stored tempo for a following "a tempo" / "tempo primo", whose stored number
    /// is meaningless and which `current` reports as the tempo it reinstates: a host that only toggles `playsBack`
    /// hands that tempo back unchanged, and must not be read as having edited the number. `nil` compares with the
    /// stored tempo.
    mutating func apply(_ marking: SetTempo.Marking, reported: SetTempo.Marking? = nil) {
        let basis = reported ?? SetTempo.Marking(beatsPerSecond: beatsPerSecond, beatNote: beatNote, beatDots: beatDots)
        let numberChanged = marking.beatsPerSecond != basis.beatsPerSecond
            || marking.beatNote != basis.beatNote || marking.beatDots != basis.beatDots
        if numberChanged {
            beatsPerSecond = marking.beatsPerSecond
            beatNote = marking.beatNote
            beatDots = marking.beatDots
        }
        if let playsBack = marking.playsBack {
            self.playsBack = playsBack
        }
        switch marking.text {
        case .derive:
            text = nil
            preservedTextMarkup = nil
            followText = true
            textType = .normal
        case let .set(newText):
            text = newText
            preservedTextMarkup = nil
        case .keep:
            if numberChanged {
                applyNumberEdit()
            }
        }
    }

    /// What a new number or beat does to the words (spec 2026-10-14 §5.6, the owner's decision b): only the equation
    /// changes, the words around it stay. The text is read as MuseScore reads it (`TempoTextEquation`), and the
    /// invariant held afterwards is that the equation the text prints equals what plays, in the text's own beat glyph:
    ///
    /// - a derived text prints the new number by itself;
    /// - a text that is an equation and nothing else becomes derived;
    /// - words around an equation, while the marking follows its text, get the number rewritten in the text's own
    ///   beat — in the plain text and in the markup, so the glyph and the formatting stay — and, when the host changed
    ///   the beat itself, the glyph rewritten to the new beat with the number counted in it;
    /// - words alone, a modulation, or a marking that does not follow its text keep their words: the number changes
    ///   what plays only.
    ///
    /// **Deviation from MuseScore:** an "a tempo" or "tempo primo" whose number is edited becomes `.normal`, words
    /// kept. MuseScore's `updateTempo` never changes a marking's type, so there the edited number of an "a tempo" is
    /// simply ignored by playback; here an edit that would be ignored is worse than the type change.
    mutating func applyNumberEdit() {
        textType = .normal
        guard text != nil else { return }
        switch TempoTextEquation(displayedRichText) {
        case .metronome(_, _, true):
            text = nil
            preservedTextMarkup = nil
            followText = true
        case let .metronome(textBeat, _, false) where followText:
            rewriteEquation(textBeatQuarters: textBeat)
        default:
            break
        }
    }

    /// Rewrites the equation in the words. While the marking's beat is the text's own, only the number is written,
    /// counted in that beat; when the host changed the beat, the glyph is rewritten too (the table the derived text
    /// uses) and the number counted in the new beat. A glyph that cannot be found to rewrite leaves the text's beat
    /// standing, with the number counted in it.
    private mutating func rewriteEquation(textBeatQuarters: Double) {
        let sameBeat = abs(textBeatQuarters - beatLengthInQuarters) < 1e-9
        let inTextBeat = Self.printedNumber(beatsPerSecond * 60 / textBeatQuarters)
        let replacement = sameBeat ? nil : metronomeMarking
        let glyphs = replacement?.symbolNames
        let number = replacement?.number ?? inTextBeat
        if let markup = preservedTextMarkup?.replacingEquation(glyphs: glyphs, number: number) {
            let plain = RichText(markup: markup).plainText
            preservedTextMarkup = PreservedTextMarkup(content: markup.content, derivedText: plain)
            text = plain
            return
        }
        preservedTextMarkup = nil
        guard var rewritten = text else { return }
        if let anchored = Self.rewrittenEquation(in: rewritten, glyphs: glyphs, number: number) {
            rewritten = anchored
        } else if let span = Self.numberSpan(in: rewritten) {
            rewritten.replaceSubrange(span, with: inTextBeat)
        }
        text = rewritten
    }

    /// The number of a "beat = number" in `text` whose beat glyph is not in the text (the glyph is a `<sym>` that plain
    /// text drops): after the first equals sign MuseScore reads (=, ≒, ≈, ~) that has one — past spaces and "ca." /
    /// "c." / "approx." — the digits, with at most one decimal point or comma inside them.
    static func numberSpan(in text: String) -> Range<String.Index>? {
        var searchStart = text.startIndex
        while let sign = text[searchStart...].firstIndex(where: { isSign(of: $0) }) {
            if let span = numberAfter(sign, in: text) {
                return span
            }
            searchStart = text.index(after: sign)
        }
        return nil
    }

    /// The number after `text`'s first non-space character when that is an equals sign: the span of a character run
    /// that follows a metronome glyph written as `<sym>`s.
    static func numberSpanAfterLeadingSign(in text: String) -> Range<String.Index>? {
        guard let sign = text.firstIndex(where: { !$0.isWhitespace }), isSign(of: text[sign]) else { return nil }
        return numberAfter(sign, in: text)
    }

    /// `text` with the equation whose beat glyph is written in it as metronome codepoints (U+ECA0–U+ECB7) rewritten:
    /// its number replaced by `number`, and its glyph by `glyphs` (SMuFL names) when given. `nil` when the text holds
    /// no such equation. Anchoring on the glyph is what keeps "2 Allegro ♩ = 120" and "x = 3 ♩ = 120" from rewriting
    /// the wrong number.
    static func rewrittenEquation(in text: String, glyphs: [String]?, number: String) -> String? {
        guard let spans = equationSpans(in: text) else { return nil }
        let scalars = text.unicodeScalars
        let glyph = glyphs.map(glyphString) ?? String(scalars[spans.glyph])
        return String(scalars[..<spans.glyph.lowerBound]) + glyph
            + String(scalars[spans.glyph.upperBound ..< spans.number.lowerBound]) + number
            + String(scalars[spans.number.upperBound...])
    }

    /// The beat glyph written as `names` (SMuFL metronome names, `space` as a space) in codepoints.
    private static func glyphString(_ names: [String]) -> String {
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

    /// The first "glyph = number" in `text`: a metronome note, up to two dots after it, an equals sign, the number.
    private static func equationSpans(in text: String) -> (glyph: Range<String.Index>, number: Range<String.Index>)? {
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            defer { index = scalars.index(after: index) }
            guard TempoTextEquation.patterns.contains(where: { $0.note == scalars[index] }) else { continue }
            var glyphEnd = scalars.index(after: index)
            for _ in 0 ..< 2 {
                let probe = skippingSpaces(from: glyphEnd, in: scalars)
                guard probe < scalars.endIndex, scalars[probe] == TempoTextEquation.dot else { break }
                glyphEnd = scalars.index(after: probe)
            }
            let sign = skippingSpaces(from: glyphEnd, in: scalars)
            if sign < scalars.endIndex, isSign(scalars[sign]), let number = numberAfter(sign, in: text) {
                return (index ..< glyphEnd, number)
            }
        }
        return nil
    }

    private static func skippingSpaces(from start: String.Index, in scalars: String.UnicodeScalarView) -> String.Index {
        var cursor = start
        while cursor < scalars.endIndex, TempoTextEquation.isSpace(scalars[cursor]) {
            cursor = scalars.index(after: cursor)
        }
        return cursor
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

    private static func isDigit(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return false }
        return TempoTextEquation.isDigit(scalar)
    }

    private static func numberAfter(_ sign: String.Index, in text: String) -> Range<String.Index>? {
        var cursor = text.index(after: sign)
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
        let start = cursor
        var end = cursor
        var separatorSeen = false
        while cursor < text.endIndex {
            let character = text[cursor]
            if isDigit(character) {
                cursor = text.index(after: cursor)
                end = cursor
            } else if character == "." || character == ",", !separatorSeen, end > start {
                separatorSeen = true
                cursor = text.index(after: cursor)
            } else {
                break
            }
        }
        return end > start ? start ..< end : nil
    }
}
