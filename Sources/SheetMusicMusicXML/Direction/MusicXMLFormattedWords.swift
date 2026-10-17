import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// A `<words>` element as MuseScore xml text (`nextPartOfFormattedString`, `importmusicxmlpass2.cpp`): its formatting
/// attributes become tags, its characters are escaped as `String::toXmlEscaped` does.
enum MusicXMLFormattedWords {
    /// The words' xml text: `font-size`, `font-family`, `font-weight`, `font-style`, `underline`, `line-through` as
    /// tags around the escaped characters, in MuseScore's order.
    static func xmlText(of node: XMLTreeNode) -> String {
        var open = ""
        var close = ""
        if let size = node.attributes["font-size"].flatMap({ Double($0) }) {
            open += "<font size=\"\(formatted(size))\"/>"
        }
        if let family = node.attributes["font-family"], !family.isEmpty {
            open += "<font face=\"\(family)\"/>"
        }
        if node.attributes["font-weight"] == "bold" {
            open += "<b>"
            close = "</b>" + close
        }
        if node.attributes["font-style"] == "italic" {
            open += "<i>"
            close = "</i>" + close
        }
        if let lines = node.attributes["underline"].flatMap({ Int($0) }), lines > 0 {
            open += "<u>"
            close = "</u>" + close
        }
        if let lines = node.attributes["line-through"].flatMap({ Int($0) }), lines > 0 {
            open += "<s>"
            close = "</s>" + close
        }
        return open + escaped(rawCharacters(of: node)) + close
    }

    /// The plain text of an xml text (`RichText.plainText`: tags dropped, entities read, symbols contribute nothing).
    static func plainText(ofXMLText xml: String) -> String {
        RichText(xmlText: xml).plainText
    }

    /// Whitespace collapsed as `QString::simplified` does: trimmed, every run one space.
    static func simplified(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The plain text an element stores, and the markup it keeps when the xml text holds any element; a plain text
    /// keeps none, as `StaffText.preservedTextMarkup(of:)` does on the MSCX side.
    static func carrier(fromXMLText xml: String) -> (plain: String, markup: PreservedTextMarkup?) {
        let markup = PreservedTextMarkup(xmlText: xml)
        let hasElement = markup.content.contains { item in
            if case .element = item { return true }
            return false
        }
        return (markup.derivedText, hasElement ? markup : nil)
    }

    /// The element's characters untrimmed: the parser keeps `mixedContent` for `words` and `rehearsal`
    /// (`MusicXMLParser.mixedContentElements`); `text`, trimmed, is the fallback.
    private static func rawCharacters(of node: XMLTreeNode) -> String {
        guard let content = node.mixedContent else { return node.text }
        var result = ""
        for item in content {
            if case let .characters(characters) = item { result += characters }
        }
        return result
    }

    /// `String::toXmlEscaped`: `&`, `<`, `>`, `"` as entities; `\r` dropped (MuseScore's `\r\n` → `\n`), and every
    /// other control character below U+0020 but tab and newline dropped. Walked by scalar: `"\r\n"` is one Character.
    private static func escaped(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\t", "\n": result.unicodeScalars.append(scalar)
            default:
                if scalar.value >= 0x20 { result.unicodeScalars.append(scalar) }
            }
        }
        return result
    }

    /// A size without a decimal point when it is integral, else Swift's shortest `Double` description.
    private static func formatted(_ size: Double) -> String {
        if size == size.rounded(), abs(size) < 1e15 { return String(Int(size)) }
        return String(size)
    }
}
