import SheetMusicFoundation

extension PreservedTextMarkup {
    private enum Search { case searching, replaced, failed }
    private enum Phase { case needSign, needNumber, done, failed }

    /// This markup with its tempo equation of beat `quarters` rewritten (`Tempo.applyNumberEdit`): the number replaced
    /// by `number`, and the beat glyph by `glyphs` (SMuFL names) when given. The equation is, in document order, the
    /// first of that beat: a run of metronome `<sym>` elements followed — in the same element list, through any
    /// formatting elements — by an equals sign and a number, or a metronome codepoint written in one character run
    /// ahead of its own " = number". `nil` when that first equation cannot be reached this way (its number sits outside
    /// the list that holds the glyph, say): the search then stops rather than rewrite a later equation, and the caller
    /// falls back to the plain text. `derivedText` is the caller's to set.
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
        guard phase == .done else {
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
            guard phase == .needSign || phase == .needNumber else {
                result.append(item)
                continue
            }
            switch item {
            case let .characters(text):
                switch Tempo.readEquationLeaf(text, afterSign: phase == .needNumber) {
                case .blank:
                    result.append(item)
                case .signOnly:
                    phase = .needNumber
                    result.append(item)
                case let .number(span):
                    var rewritten = text
                    rewritten.replaceSubrange(span, with: number)
                    phase = .done
                    result.append(.characters(rewritten))
                case .unrelated:
                    phase = .failed
                    result.append(item)
                }
            case let .element(element):
                let inner = replacingNumber(in: element.content, number: number, phase: &phase)
                result.append(.element(Element(name: element.name, attributes: element.attributes, content: inner)))
            }
        }
        return result
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
