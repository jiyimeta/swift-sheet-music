import SheetMusicFoundation

extension PreservedTextMarkup {
    private enum Search { case searching, replaced, failed }
    /// `consuming*`: the number's digits ran to the end of a run, so the next runs' leading digits belong to it too.
    private enum Phase { case needSign, needNumber, consuming, consumingAfterSeparator, done, failed }

    /// This markup with its tempo equation of beat `quarters` rewritten (`Tempo.applyNumberEdit`): the number replaced
    /// by `number`, and the beat glyph by `glyphs` (SMuFL names) when given. The equation is, in document order, the
    /// first of that beat: a run of metronome `<sym>` elements followed — in the same element list, through any
    /// formatting elements — by an equals sign and a number (the new number goes in the run that holds the number's
    /// first digit, and the rest of its digits are removed from the runs after it), or a metronome codepoint written
    /// in one character run ahead of its own " = number". `nil` when no equation was rewritten: a symbol run of the
    /// wanted beat whose number cannot be reached ends the search at once (the number sits outside the list that holds
    /// the glyph, say). A codepoint glyph whose number sits in a later run does not — the search goes on, and
    /// the caller's cross-check of the markup's plain text against the plain-text rewrite is what rejects a wrong
    /// equation. The caller then falls back to the plain text. `derivedText` is the caller's to set.
    func replacingEquation(glyphs: [String]?, number: String, quarters: Double) -> PreservedTextMarkup? {
        var search = Search.searching
        let rewritten = Self.replacingEquation(
            in: content, glyphs: glyphs, number: number, quarters: quarters, search: &search,
        )
        return search == .replaced ? PreservedTextMarkup(content: rewritten, derivedText: derivedText) : nil
    }

    private static func replacingEquation(
        in items: [ContentItem], glyphs: [String]?, number: String, quarters: Double, search: inout Search,
    ) -> [ContentItem] {
        var result: [ContentItem] = []
        var index = 0
        while index < items.count {
            let item = items[index]
            guard search == .searching else {
                result.append(item)
                index += 1
                continue
            }
            switch item {
            case let .characters(text):
                if let rewritten = Tempo.rewrittenEquation(
                    in: text, glyphs: glyphs, number: number, quarters: quarters,
                ) {
                    result.append(.characters(rewritten))
                    search = .replaced
                } else {
                    result.append(item)
                }
                index += 1
            case let .element(element) where symbolName(of: element) != nil:
                let end = endOfSymbolRun(from: index, in: items)
                index = rewriteRun(
                    of: items, from: index, to: end, glyphs: glyphs, number: number, quarters: quarters,
                    into: &result, search: &search,
                )
            case let .element(element):
                let inner = replacingEquation(
                    in: element.content, glyphs: glyphs, number: number, quarters: quarters, search: &search,
                )
                result.append(.element(Element(name: element.name, attributes: element.attributes, content: inner)))
                index += 1
            }
        }
        return result
    }

    /// Handles the symbol run `items[start ..< end]`: when it is a glyph of the wanted beat, its equation is this one —
    /// rewritten if the number can be reached after it, otherwise the search fails. Returns the index to go on from.
    private static func rewriteRun(
        of items: [ContentItem], from start: Int, to end: Int, glyphs: [String]?, number: String, quarters: Double,
        into result: inout [ContentItem], search: inout Search,
    ) -> Int {
        let names = items[start ..< end].compactMap { item -> String? in
            if case let .element(element) = item { symbolName(of: element) } else { nil }
        }
        guard let length = Tempo.beatQuarters(ofSymbols: names), abs(length - quarters) < 1e-9 else {
            result += items[start ..< end]
            return end
        }
        var phase = Phase.needSign
        let tail = replacingNumber(in: Array(items[end...]), number: number, phase: &phase)
        guard phase == .done || phase == .consuming || phase == .consumingAfterSeparator else {
            search = .failed
            result += items[start...]
            return items.count
        }
        result += glyphs.map(symbolItems) ?? Array(items[start ..< end])
        result += tail
        search = .replaced
        return items.count
    }

    /// Replaces the number that continues an equation after its glyph, reading the character runs in document order:
    /// blanks, then an equals sign, then the number — which may sit in a later run, inside a formatting element.
    private static func replacingNumber(in items: [ContentItem], number: String, phase: inout Phase) -> [ContentItem] {
        var result: [ContentItem] = []
        for item in items {
            guard phase != .done, phase != .failed else {
                result.append(item)
                continue
            }
            switch item {
            case let .characters(text):
                result.append(.characters(rewritingLeaf(text, number: number, phase: &phase)))
            case let .element(element):
                let inner = replacingNumber(in: element.content, number: number, phase: &phase)
                result.append(.element(Element(name: element.name, attributes: element.attributes, content: inner)))
            }
        }
        return result
    }

    private static func rewritingLeaf(_ text: String, number: String, phase: inout Phase) -> String {
        if phase == .consuming || phase == .consumingAfterSeparator {
            return droppingLeadingDigits(of: text, phase: &phase)
        }
        switch Tempo.readEquationLeaf(text, afterSign: phase == .needNumber) {
        case .blank:
            return text
        case .signOnly:
            phase = .needNumber
            return text
        case let .number(span):
            let hasSeparator = text[span].contains { $0 == "." || $0 == "," }
            var rewritten = text
            rewritten.replaceSubrange(span, with: number)
            if span.upperBound == text.endIndex {
                phase = hasSeparator ? .consumingAfterSeparator : .consuming
            } else {
                phase = .done
            }
            return rewritten
        case .unrelated:
            phase = .failed
            return text
        }
    }

    /// The rest of a number whose digits ran to the end of the previous run: `text` without its leading digits (and
    /// one decimal point or comma between them, if the number has none yet). The number goes on only if the run is
    /// all digits.
    private static func droppingLeadingDigits(of text: String, phase: inout Phase) -> String {
        guard !text.isEmpty else { return text }
        var cursor = text.startIndex
        var separatorSeen = phase == .consumingAfterSeparator
        while cursor < text.endIndex {
            let character = text[cursor]
            let next = text.index(after: cursor)
            if Tempo.isDigit(character) {
                cursor = next
            } else if character == "." || character == ",", !separatorSeen, next < text.endIndex,
                      Tempo.isDigit(text[next])
            {
                separatorSeen = true
                cursor = next
            } else {
                break
            }
        }
        if cursor == text.endIndex {
            phase = separatorSeen ? .consumingAfterSeparator : .consuming
        } else {
            phase = .done
        }
        return String(text[cursor...])
    }

    /// The name inside a `<sym>` of the metronome range (or the `space` between a note and its dots).
    private static func symbolName(of element: Element) -> String? {
        guard element.name == "sym", element.content.count == 1, case let .characters(name) = element.content[0],
              Tempo.isMetronomeSymbolName(name)
        else { return nil }
        return name
    }

    /// The index after the last of the consecutive metronome `<sym>`s starting at `start`.
    private static func endOfSymbolRun(from start: Int, in items: [ContentItem]) -> Int {
        var end = start
        while end < items.count, case let .element(element) = items[end], symbolName(of: element) != nil {
            end += 1
        }
        return end
    }

    private static func symbolItems(_ names: [String]) -> [ContentItem] {
        names.map { .element(Element(name: "sym", content: [.characters($0)])) }
    }
}
