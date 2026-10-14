import SheetMusicFoundation

extension PreservedTextMarkup {
    /// This markup with its tempo equation rewritten (`Tempo.applyNumberEdit`): the number replaced by `number`, and
    /// the beat glyph by `glyphs` (SMuFL names) when given. The equation is a run of metronome `<sym>` elements
    /// followed by a character run that opens with an equals sign and a number, or a metronome codepoint written in
    /// one character run ahead of its own " = number". `nil` when no single run holds one — the number sits behind
    /// another tag, say. `derivedText` is the caller's to set.
    func replacingEquation(glyphs: [String]?, number: String) -> PreservedTextMarkup? {
        var replaced = false
        let rewritten = Self.replacingEquation(in: content, glyphs: glyphs, number: number, replaced: &replaced)
        return replaced ? PreservedTextMarkup(content: rewritten, derivedText: derivedText) : nil
    }

    private static func replacingEquation(
        in items: [ContentItem], glyphs: [String]?, number: String, replaced: inout Bool,
    ) -> [ContentItem] {
        var result: [ContentItem] = []
        var index = 0
        while index < items.count {
            let item = items[index]
            if replaced {
                result.append(item)
                index += 1
                continue
            }
            switch item {
            case let .characters(text):
                if let rewritten = Tempo.rewrittenEquation(in: text, glyphs: glyphs, number: number) {
                    result.append(.characters(rewritten))
                    replaced = true
                } else {
                    result.append(item)
                }
                index += 1
            case let .element(element) where isMetronomeSymbol(element):
                let end = endOfSymbolRun(from: index, in: items)
                if end < items.count, case let .characters(text) = items[end],
                   let span = Tempo.numberSpanAfterLeadingSign(in: text)
                {
                    var rewritten = text
                    rewritten.replaceSubrange(span, with: number)
                    result += glyphs.map(symbolItems) ?? Array(items[index ..< end])
                    result.append(.characters(rewritten))
                    replaced = true
                    index = end + 1
                } else {
                    result += items[index ..< end]
                    index = end
                }
            case let .element(element):
                let inner = replacingEquation(in: element.content, glyphs: glyphs, number: number, replaced: &replaced)
                result.append(.element(Element(name: element.name, attributes: element.attributes, content: inner)))
                index += 1
            }
        }
        return result
    }

    /// A `<sym>` of the metronome range (or the `space` between a note and its dots) — what `TempoTextEquation` reads.
    private static func isMetronomeSymbol(_ element: Element) -> Bool {
        guard element.name == "sym", element.content.count == 1, case let .characters(name) = element.content[0]
        else { return false }
        return name == "space" || TempoTextEquation.metronomeCodepoints[name] != nil
    }

    /// The index after the last of the consecutive metronome `<sym>`s starting at `start`.
    private static func endOfSymbolRun(from start: Int, in items: [ContentItem]) -> Int {
        var end = start
        while end < items.count, case let .element(element) = items[end], isMetronomeSymbol(element) {
            end += 1
        }
        return end
    }

    private static func symbolItems(_ names: [String]) -> [ContentItem] {
        names.map { .element(Element(name: "sym", content: [.characters($0)])) }
    }
}
