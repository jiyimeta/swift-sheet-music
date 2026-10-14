import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Tempo {
    /// Build a `<Tempo>` element in `TWrite::write(const TempoText*)`'s order (`rw/write/twrite.cpp:3163-3181`):
    /// `<play>0</play>` for a muted marking, `<tempo>`, `<followText>1</followText>` when the marking follows a text it
    /// has, `<type>` when not `.normal`; then `writeProperties(TextBase*)` — `<eid>`, the element properties, the text
    /// properties, the children nothing models — and `<text>` last, before the shared trailing `<color>`.
    ///
    /// The text is the authored markup verbatim while it still describes `text`, else the authored `text` plain, else
    /// the derived marking (`markingText`) — byte-identical to what every derived tempo wrote before.
    func encode(eid: EID, options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if !playsBack {
            children.append(XMLTreeNode(name: "play", text: "0"))
        }
        children.append(XMLTreeNode(name: "tempo", text: formatDouble(beatsPerSecond)))
        let textNode = text.map { encodeText($0, preservedTextMarkup: preservedTextMarkup, options: options) }
            ?? markingText
        if followText, textNode != nil {
            children.append(XMLTreeNode(name: "followText", text: "1"))
        }
        if textType != .normal {
            children.append(XMLTreeNode(name: "type", text: textType.rawValue))
        }
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
        children.append(contentsOf: elementProperties.mscxChildren())
        properties.appendXML(to: &children)
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        if let textNode {
            children.append(textNode)
        }
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "Tempo", children: children)
    }

    /// The derived marking (`metronomeMarking`) in the `<sym>` markup MuseScore's palette writes, inline through
    /// `mixedContent` — `<text><sym>metNoteQuarterUp</sym> = 120</text>` on one line, as MuseScore's writer emits it.
    /// It must not be pretty-printed: the indentation between tags is character data MuseScore reads as text, and it
    /// opened the old one-child-per-line form as two lines. `nil` when there is no marking to print.
    var markingText: XMLTreeNode? {
        guard let marking = metronomeMarking else { return nil }
        let symbols = marking.symbolNames.map { XMLTreeNode(name: "sym", text: $0) }
        return XMLTreeNode(
            name: "text",
            text: marking.trailingText.trimmingWhitespaceAndNewlines(),
            children: symbols,
            mixedContent: symbols.map(XMLContentItem.element) + [.characters(marking.trailingText)],
        )
    }
}
