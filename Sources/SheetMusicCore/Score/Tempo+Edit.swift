import SheetMusicFoundation

extension Tempo {
    /// Writes `marking` (`SetTempo`): the number and beat, `<play>` when it says, and the text as its `TextEdit` says —
    /// `.keep` leaving the words to MuseScore's number-edit rule when the number or the beat moved
    /// (`applyNumberEdit`).
    mutating func apply(_ marking: SetTempo.Marking) {
        let numberChanged = marking.beatsPerSecond != beatsPerSecond
            || marking.beatNote != beatNote || marking.beatDots != beatDots
        beatsPerSecond = marking.beatsPerSecond
        beatNote = marking.beatNote
        beatDots = marking.beatDots
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

    /// What a new number does to the words (spec 2026-10-14 §5.6, the owner's decision b), read as MuseScore reads them
    /// (`TempoTextEquation`):
    ///
    /// - a derived text prints the new number by itself;
    /// - a text that is an equation and nothing else becomes derived;
    /// - words around an equation, while the marking follows its text, get the new number written into the equation —
    ///   in the plain text and in the markup, so the glyph and the formatting stay;
    /// - words alone, a modulation, or a marking that does not follow its text keep their words: the number changes
    ///   what plays only.
    ///
    /// An "a tempo" or "tempo primo" whose number is edited now states a tempo: it becomes `.normal`, words kept.
    mutating func applyNumberEdit() {
        textType = .normal
        guard text != nil else { return }
        switch TempoTextEquation(displayedRichText) {
        case .metronome(_, _, true):
            text = nil
            preservedTextMarkup = nil
            followText = true
        case .metronome(_, _, false) where followText:
            rewriteNumber(to: Self.printedNumber(beatsPerMinute))
        default:
            break
        }
    }

    /// Writes `number` over the equation's number: in `text`, and in the markup when one character run of it holds the
    /// same span. When none does, the markup — which no longer describes the text — is dropped and the words stay.
    mutating func rewriteNumber(to number: String) {
        guard var rewritten = text, let span = Self.numberSpan(in: rewritten) else { return }
        rewritten.replaceSubrange(span, with: number)
        if let markup = preservedTextMarkup?.replacingFirstNumber(with: number),
           RichText(markup: markup).plainText == rewritten
        {
            preservedTextMarkup = PreservedTextMarkup(content: markup.content, derivedText: rewritten)
        } else {
            preservedTextMarkup = nil
        }
        text = rewritten
    }

    /// The number of a "beat = number" in `text`: after the first equals sign MuseScore reads (=, ≒, ≈, ~) that has one
    /// — past spaces and "ca." / "c." / "approx." — the digits, with at most one decimal point or comma inside them.
    static func numberSpan(in text: String) -> Range<String.Index>? {
        var searchStart = text.startIndex
        while let sign = text[searchStart...].firstIndex(where: { "=≒≈~".contains($0) }) {
            if let span = numberAfter(sign, in: text) {
                return span
            }
            searchStart = text.index(after: sign)
        }
        return nil
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

extension PreservedTextMarkup {
    /// This markup with the first number `Tempo.numberSpan` finds in one of its character runs replaced by `number`;
    /// `nil` when no single run holds one. `derivedText` is the caller's to set.
    func replacingFirstNumber(with number: String) -> PreservedTextMarkup? {
        var replaced = false
        let rewritten = Self.replacingFirstNumber(in: content, with: number, replaced: &replaced)
        return replaced ? PreservedTextMarkup(content: rewritten, derivedText: derivedText) : nil
    }

    private static func replacingFirstNumber(
        in items: [ContentItem], with number: String, replaced: inout Bool,
    ) -> [ContentItem] {
        var result: [ContentItem] = []
        for item in items {
            guard !replaced else {
                result.append(item)
                continue
            }
            switch item {
            case var .characters(text):
                if let span = Tempo.numberSpan(in: text) {
                    text.replaceSubrange(span, with: number)
                    replaced = true
                }
                result.append(.characters(text))
            case let .element(element):
                result.append(.element(Element(
                    name: element.name, attributes: element.attributes,
                    content: replacingFirstNumber(in: element.content, with: number, replaced: &replaced),
                )))
            }
        }
        return result
    }
}
