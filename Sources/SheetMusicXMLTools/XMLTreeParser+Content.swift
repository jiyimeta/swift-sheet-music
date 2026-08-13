/// Character data, attribute values, and the constructs the parser skips.
extension XMLTreeParser {
    // MARK: - Character data

    /// Accumulate one run of character data onto the open element's text.
    ///
    /// XML 1.0 §2.11 line-end normalization applies to literal bytes: `\r\n`
    /// and a lone `\r` both become `\n`. Characters produced by references are
    /// exempt, so `&#xD;` survives as a carriage return.
    static func scanCharacterData(_ scanner: inout XMLScanner, into out: inout String) throws {
        var runStart = scanner.index
        while let byte = scanner.peek() {
            switch byte {
            case UInt8(ascii: "<"):
                scanner.appendText(runStart ..< scanner.index, to: &out)
                return
            case UInt8(ascii: "&"):
                scanner.appendText(runStart ..< scanner.index, to: &out)
                try scanner.scanReference(into: &out)
                runStart = scanner.index
            case 0x0D:
                scanner.appendText(runStart ..< scanner.index, to: &out)
                out.append("\n")
                scanner.advance()
                if scanner.peek() == 0x0A { scanner.advance() }
                runStart = scanner.index
            case UInt8(ascii: "]") where scanner.matches(Token.cdataClose):
                throw scanner.error("']]>' must be escaped in character data")
            default:
                if byte < 0x20, byte != 0x09, byte != 0x0A {
                    throw scanner.error("control character in character data")
                }
                scanner.advance()
            }
        }
        scanner.appendText(runStart ..< scanner.index, to: &out)
    }

    /// CDATA contributes to the same text buffer as ordinary character data —
    /// the previous delegate implemented no `foundCDATA`, so Foundation routed
    /// it through `foundCharacters`.
    static func scanCDATA(_ scanner: inout XMLScanner, into out: inout String) throws {
        let start = scanner.index
        scanner.advance(Token.cdataOpen.count)
        var runStart = scanner.index
        while !scanner.isAtEnd {
            if scanner.matches(Token.cdataClose) {
                scanner.appendText(runStart ..< scanner.index, to: &out)
                scanner.advance(Token.cdataClose.count)
                return
            }
            if scanner.peek() == 0x0D {
                scanner.appendText(runStart ..< scanner.index, to: &out)
                out.append("\n")
                scanner.advance()
                if scanner.peek() == 0x0A { scanner.advance() }
                runStart = scanner.index
                continue
            }
            scanner.advance()
        }
        throw scanner.error("unterminated CDATA section", at: start)
    }

    // MARK: - Attribute values

    /// §3.3.3 attribute-value normalization for CDATA-typed attributes (which
    /// is all of them without a DTD): after line-end normalization, literal
    /// tabs and newlines each become a single space. Reference-produced
    /// characters are again exempt.
    static func scanAttributeValue(_ scanner: inout XMLScanner) throws -> String {
        guard let quote = scanner.peek(),
              quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'")
        else {
            throw scanner.error("attribute value must be quoted")
        }
        let start = scanner.index
        scanner.advance()

        var out = ""
        var runStart = scanner.index
        while let byte = scanner.peek() {
            switch byte {
            case quote:
                scanner.appendText(runStart ..< scanner.index, to: &out)
                scanner.advance()
                return out
            case UInt8(ascii: "&"):
                scanner.appendText(runStart ..< scanner.index, to: &out)
                try scanner.scanReference(into: &out)
                runStart = scanner.index
            case UInt8(ascii: "<"):
                throw scanner.error("'<' must be escaped in an attribute value")
            case 0x0D:
                scanner.appendText(runStart ..< scanner.index, to: &out)
                out.append(" ")
                scanner.advance()
                if scanner.peek() == 0x0A { scanner.advance() }
                runStart = scanner.index
            case 0x0A, 0x09:
                scanner.appendText(runStart ..< scanner.index, to: &out)
                out.append(" ")
                scanner.advance()
                runStart = scanner.index
            default:
                if byte < 0x20 {
                    throw scanner.error("control character in attribute value")
                }
                scanner.advance()
            }
        }
        throw scanner.error("unterminated attribute value", at: start)
    }

    // MARK: - Skipped constructs

    static func skipComment(_ scanner: inout XMLScanner) throws {
        let start = scanner.index
        scanner.advance(Token.commentOpen.count)
        while !scanner.isAtEnd {
            if scanner.matches(Token.commentClose) {
                scanner.advance(Token.commentClose.count)
                return
            }
            if scanner.peek() == UInt8(ascii: "-"), scanner.peek(1) == UInt8(ascii: "-") {
                throw scanner.error("'--' is not allowed inside a comment")
            }
            scanner.advance()
        }
        throw scanner.error("unterminated comment", at: start)
    }

    static func skipProcessingInstruction(_ scanner: inout XMLScanner) throws {
        let start = scanner.index
        scanner.advance(Token.piOpen.count)
        while !scanner.isAtEnd {
            if scanner.matches(Token.piClose) {
                scanner.advance(Token.piClose.count)
                return
            }
            scanner.advance()
        }
        throw scanner.error("unterminated processing instruction", at: start)
    }

    /// Skipped wholesale, including any internal subset. Quote- and
    /// bracket-aware so a `>` inside either does not end it early. External
    /// DTDs are never fetched, matching `shouldResolveExternalEntities = false`.
    static func skipDoctype(_ scanner: inout XMLScanner) throws {
        let start = scanner.index
        scanner.advance(Token.doctypeOpen.count)
        var depth = 0
        var quote: UInt8?
        while let byte = scanner.peek() {
            scanner.advance()
            if let active = quote {
                if byte == active { quote = nil }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""), UInt8(ascii: "'"): quote = byte
            case UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "]"): depth -= 1
            case UInt8(ascii: ">") where depth <= 0: return
            default: break
            }
        }
        throw scanner.error("unterminated DOCTYPE declaration", at: start)
    }

    // MARK: - Trimming

    /// Matches `String.trimmingCharacters(in: .whitespacesAndNewlines)`, which
    /// is Unicode `White_Space` — notably including U+00A0 and U+3000, so
    /// ideographic spaces in Japanese scores keep being trimmed. Compared at
    /// scalar level: a combining mark after a space forms a non-whitespace
    /// grapheme, which would make a `Character`-based trim disagree.
    static func trimmed(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, isXMLTrimmable(scalars[start]) {
            start = scalars.index(after: start)
        }
        while start < end {
            let previous = scalars.index(before: end)
            guard isXMLTrimmable(scalars[previous]) else { break }
            end = previous
        }
        guard start != scalars.startIndex || end != scalars.endIndex else { return text }
        return String(String.UnicodeScalarView(scalars[start ..< end]))
    }

    private static func isXMLTrimmable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09 ... 0x0D, 0x20, 0x85, 0xA0, 0x1680,
             0x2000 ... 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }
}
