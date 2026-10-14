import SheetMusicFoundation

/// MuseScore's text format state machine (`TextBase::createBlocks` / `prepareFormat`,
/// `engraving/dom/textbase.cpp:1659-1818`), fed by `RichText`'s two readers.
struct RichTextBuilder {
    private var lines: [[RichTextRun]] = [[]]
    private var format = RichTextFormat()
    /// The name collected so far inside `<sym>…</sym>`; `nil` outside one.
    private var symbolName: String?

    var richText: RichText {
        RichText(lines: lines)
    }

    // MARK: - The <text> element tree

    /// Walks `content` in source order. Character data that is only whitespace is skipped: MuseScore parses with
    /// pugixml's `parse_default`, which drops whitespace-only text nodes
    /// (`framework/global/serialization/xmlstreamreader.cpp:109`).
    mutating func walk(_ content: [PreservedTextMarkup.ContentItem]) {
        var pending = ""
        for item in content {
            switch item {
            case let .characters(text):
                pending += text
            case let .element(element):
                flush(&pending)
                // An element with no content is a self-closing tag; only `br` and `font` mean anything then.
                if element.content.isEmpty, !Self.selfClosingNames.contains(element.name) { continue }
                openTag(element.name, attributes: element.attributes)
                walk(element.content)
                closeTag(element.name)
            }
        }
        flush(&pending)
    }

    /// The only tags `createBlocks` acts on when written self-closing (`<br/>`, `<font …/>`); its token for any other
    /// (`i/`) matches nothing.
    private static let selfClosingNames: Set = ["br", "font"]

    /// pugixml's `parse_default` drops a text node made entirely of ASCII space, tab, CR and LF — not other Unicode
    /// whitespace such as U+00A0 or U+3000, which stay as text.
    private mutating func flush(_ pending: inout String) {
        defer { pending = "" }
        let isWhitespaceOnly = pending.unicodeScalars.allSatisfy { " \t\n\r".unicodeScalars.contains($0) }
        guard !isWhitespaceOnly else { return }
        appendCharacters(pending)
    }

    // MARK: - xml text held as a string

    /// `createBlocks`' character loop over a string: `<…>` is a tag and `&…;` an entity. A `<` that no `>` closes
    /// before the next `<`, and an `&` that starts no entity `createBlocks` knows, are literal characters — MuseScore
    /// escapes both, so this changes nothing it writes and keeps a label typed as text intact.
    mutating func parse(_ xmlText: String) {
        let source = Array(xmlText)
        var pending = ""
        var index = 0
        while index < source.count {
            let character = source[index]
            if character == "<", let end = Self.tagEnd(in: source, from: index) {
                appendCharacters(pending)
                pending = ""
                tag(String(source[(index + 1) ..< end]))
                index = end + 1
            } else if character == "&", let entity = Self.entity(in: source, at: index) {
                pending.append(entity.character)
                index = entity.next
            } else {
                pending.append(character)
                index += 1
            }
        }
        appendCharacters(pending)
    }

    /// `token` is what sits between `<` and `>`: `b`, `/b`, `font size="12"/`, `sym`, `br/`.
    private mutating func tag(_ token: String) {
        var body = token.trimmingWhitespaceAndNewlines()
        let selfClosing = body.hasSuffix("/")
        if selfClosing { body.removeLast() }
        if body.hasPrefix("/") {
            closeTag(String(body.dropFirst()).trimmingWhitespaceAndNewlines())
            return
        }
        let name = String(body.prefix { !$0.isWhitespace })
        if selfClosing, !Self.selfClosingNames.contains(name) { return }
        openTag(name, attributes: Self.attributes(in: body.dropFirst(name.count)))
    }

    /// The index of the `>` closing the tag opened at `start`, or `nil` when another `<` or the end comes first.
    private static func tagEnd(in source: [Character], from start: Int) -> Int? {
        var index = start + 1
        while index < source.count {
            switch source[index] {
            case ">": return index
            case "<": return nil
            default: index += 1
            }
        }
        return nil
    }

    /// `&apos;` is decoded on purpose: createBlocks drops it, but MuseScore never writes it; typed text reads better.
    private static let entities: [String: Character] = [
        "lt": "<", "gt": ">", "amp": "&", "quot": "\"", "apos": "'",
    ]

    /// The entity starting at `start` and the index after its `;`, or `nil` when it names none of `entities`.
    private static func entity(in source: [Character], at start: Int) -> (character: Character, next: Int)? {
        let end = min(source.count, start + 6)
        guard start + 1 < end,
              let semicolon = source[(start + 1) ..< end].firstIndex(of: ";"),
              let character = entities[String(source[(start + 1) ..< semicolon])]
        else { return nil }
        return (character, semicolon + 1)
    }

    /// `name="value"` pairs, either quote, values entity-decoded as MuseScore's `unEscape` decodes a face.
    private static func attributes(in source: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var rest = source
        while let equals = rest.firstIndex(of: "=") {
            let name = rest[..<equals].trimmingWhitespaceAndNewlines()
            let value = rest[rest.index(after: equals)...].drop(while: { $0 == " " })
            guard let quote = value.first, quote == "\"" || quote == "'",
                  let close = value.dropFirst().firstIndex(of: quote)
            else { break }
            result[name] = decodeEntities(String(value[value.index(after: value.startIndex) ..< close]))
            rest = value[value.index(after: close)...]
        }
        return result
    }

    private static func decodeEntities(_ text: String) -> String {
        let source = Array(text)
        var result = ""
        var index = 0
        while index < source.count {
            if source[index] == "&", let entity = Self.entity(in: source, at: index) {
                result.append(entity.character)
                index = entity.next
            } else {
                result.append(source[index])
                index += 1
            }
        }
        return result
    }

    // MARK: - Events

    /// Characters in the current format. A line feed starts a line even inside `<sym>`: `createBlocks` tests for it
    /// before it tests the symbol state.
    private mutating func appendCharacters(_ text: String) {
        let segments = Self.normalizingLineEnds(text).split(separator: "\n", omittingEmptySubsequences: false)
        for (index, segment) in segments.enumerated() {
            if index > 0 { lines.append([]) }
            guard !segment.isEmpty else { continue }
            if symbolName != nil {
                symbolName?.append(contentsOf: segment)
            } else {
                appendText(String(segment))
            }
        }
    }

    /// CRLF and a lone CR become LF, as the XML parser normalizes them. Done on scalars because Swift reads "\r\n" as
    /// one `Character`, which a split on "\n" would never see.
    private static func normalizingLineEnds(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n", previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = scalar == "\r"
            result.append(scalar == "\r" ? "\n" : scalar)
        }
        return String(result)
    }

    /// `prepareFormat` sets bold, italic, underline, strike, the vertical alignment, and the font's size or face;
    /// `sym` starts collecting a name; `br` is the `"\n"` `TRead::lineBreakFromTag` turns it into
    /// (`rw/read460/tread.cpp:3831-3835`). Any other tag is ignored, as `prepareFormat` ignores it.
    private mutating func openTag(_ name: String, attributes: [String: String]) {
        switch name {
        case "b": format.bold = true
        case "i": format.italic = true
        case "u": format.underline = true
        case "s": format.strike = true
        case "sub": format.verticalAlign = .subScript
        case "sup": format.verticalAlign = .superScript
        case "font":
            if let size = attributes["size"].flatMap({ Double($0) }) { format.size = size }
            if let face = attributes["face"] { format.face = face }
        case "sym": symbolName = ""
        case "br": lines.append([])
        default: break
        }
    }

    /// Closing sets a state off rather than restoring what it was: `</b>` makes what follows regular even inside an
    /// outer `<b>`. `</sym>` appends the symbol run in the current format.
    private mutating func closeTag(_ name: String) {
        switch name {
        case "b": format.bold = false
        case "i": format.italic = false
        case "u": format.underline = false
        case "s": format.strike = false
        case "sub", "sup": format.verticalAlign = .normal
        case "sym":
            if let symbolName, !symbolName.isEmpty {
                lines[lines.count - 1].append(.symbol(name: symbolName, format))
            }
            symbolName = nil
        default: break
        }
    }

    /// Appends to the line's last run when it is text in the same format, so a run is never split by markup that did
    /// not change the format.
    private mutating func appendText(_ text: String) {
        let line = lines.count - 1
        if case let .text(existing, existingFormat)? = lines[line].last, existingFormat == format {
            lines[line][lines[line].count - 1] = .text(existing + text, format)
        } else {
            lines[line].append(.text(text, format))
        }
    }
}
