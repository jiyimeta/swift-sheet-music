import SheetMusicFoundation

/// Preserved markup and MuseScore xml text — the string a `TextBase` holds as its `xmlText` and writes as `<text>`'s
/// content — in both directions, for a text that travels as a string: a copied dynamic's own text
/// (`Dynamic.customXMLText`) and the `SetDynamic` that writes it back.
extension PreservedTextMarkup {
    /// This markup as MuseScore xml text: characters escaped (`&`, `<`, `>`), each element `<name …>…</name>`, or
    /// `<name …/>` when it has no content — the form MuseScore's reader re-serializes a childless element in
    /// (`XmlReader::htmlToString`, `engraving/rw/xmlreader.cpp:169-176`). Attributes in name order, `"` escaped.
    var xmlText: String {
        Self.xmlText(of: content)
    }

    /// MuseScore xml text read back into markup — `xmlText`'s inverse — with `derivedText` its plain projection
    /// (`RichText.plainText`), as a decoder derives it. Tags and entities are read as `RichText(xmlText:)` reads them:
    /// a `<` that no `>` closes and an `&` that starts no known entity stay characters. A tag left open closes at the
    /// end; a closing tag closes every tag opened after its match; one with no match is dropped. The text may be a
    /// peer's or another app's, so a tag whose name is not a plain word, an attribute whose name is not, and an
    /// element nested past `maximumNesting` are dropped too, their characters kept.
    init(xmlText: String) {
        let source = Array(xmlText)
        var open = [OpenElement(name: "", attributes: [:])]
        var characters = ""
        var index = 0
        while index < source.count {
            let character = source[index]
            if character == "<", let end = RichTextBuilder.tagEnd(in: source, from: index) {
                open[open.count - 1].append(characters: &characters)
                Self.read(tag: String(source[(index + 1) ..< end]), into: &open)
                index = end + 1
            } else if character == "&", let entity = RichTextBuilder.entity(in: source, at: index) {
                characters.append(entity.character)
                index = entity.next
            } else {
                characters.append(character)
                index += 1
            }
        }
        open[open.count - 1].append(characters: &characters)
        while open.count > 1 {
            Self.close(&open)
        }
        let content = open[0].content
        self.init(content: content, derivedText: RichText(content: content).plainText)
    }

    /// How deep `init(xmlText:)` nests elements, the root's content being level 1. MuseScore's own formatting stacks a
    /// handful (`<b><i><u><s><font>` and a `<sub>`); the bound is for text that is not MuseScore's.
    static let maximumNesting = 16

    /// Plain text as MuseScore xml text: `&`, `<` and `>` escaped, nothing else changed.
    static func escapedXMLText(_ text: String) -> String {
        escaped(text, quotes: false)
    }

    /// An element being read: its name, its attributes and what it holds so far. The root has no name.
    private struct OpenElement {
        let name: String
        let attributes: [String: String]
        var content: [ContentItem] = []

        /// Moves the pending characters into this element, leaving `characters` empty.
        mutating func append(characters: inout String) {
            guard !characters.isEmpty else { return }
            content.append(.characters(characters))
            characters = ""
        }
    }

    /// `token` is what sits between `<` and `>`: `b`, `/b`, `font size="12"/`, `br/`.
    private static func read(tag token: String, into open: inout [OpenElement]) {
        var body = token.trimmingWhitespaceAndNewlines()
        let selfClosing = body.hasSuffix("/")
        if selfClosing { body.removeLast() }
        if body.hasPrefix("/") {
            let name = String(body.dropFirst()).trimmingWhitespaceAndNewlines()
            guard let match = open.lastIndex(where: { $0.name == name }), match > 0 else { return }
            while open.count > match {
                close(&open)
            }
            return
        }
        let name = String(body.prefix { !$0.isWhitespace })
        // Untrusted text: a name that is not a plain word would make the saved `<text>` malformed, and nesting past
        // the bound would recurse without one — such a tag is dropped, its characters kept.
        guard isPlainName(name), selfClosing || open.count <= maximumNesting else { return }
        let attributes = RichTextBuilder.attributes(in: body.dropFirst(name.count)).filter { isPlainName($0.key) }
        if selfClosing {
            open[open.count - 1].content.append(.element(Element(name: name, attributes: attributes)))
        } else {
            open.append(OpenElement(name: name, attributes: attributes))
        }
    }

    /// An element or attribute name as MuseScore writes them: a letter, then letters and digits (`b`, `font`, `size`).
    private static func isPlainName(_ name: String) -> Bool {
        func isLetter(_ scalar: Unicode.Scalar) -> Bool {
            ("a" ... "z").contains(scalar) || ("A" ... "Z").contains(scalar)
        }
        guard let first = name.unicodeScalars.first, isLetter(first) else { return false }
        return name.unicodeScalars.allSatisfy { isLetter($0) || ("0" ... "9").contains($0) }
    }

    private static func close(_ open: inout [OpenElement]) {
        let element = open.removeLast()
        open[open.count - 1].content.append(.element(Element(
            name: element.name, attributes: element.attributes, content: element.content,
        )))
    }

    private static func xmlText(of items: [ContentItem]) -> String {
        var result = ""
        for item in items {
            switch item {
            case let .characters(text):
                result += escaped(text, quotes: false)
            case let .element(element):
                let attributes = element.attributes.sorted { $0.key < $1.key }
                    .map { " \($0.key)=\"\(escaped($0.value, quotes: true))\"" }
                    .joined()
                if element.content.isEmpty {
                    result += "<\(element.name)\(attributes)/>"
                } else {
                    result += "<\(element.name)\(attributes)>\(xmlText(of: element.content))</\(element.name)>"
                }
            }
        }
        return result
    }

    private static func escaped(_ text: String, quotes: Bool) -> String {
        var result = ""
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"" where quotes: result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }
}
