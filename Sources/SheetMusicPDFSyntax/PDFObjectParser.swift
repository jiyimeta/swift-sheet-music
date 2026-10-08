import SheetMusicFoundation

/// A bounded recursive-descent reader of PDF object syntax over a byte buffer, from `pos`. Stream framing — the
/// `stream` … `endstream` payload after a dictionary — is the caller's, since each reader finds a payload its own way.
///
/// The two readers that use it want different things from a malformed file. The incremental writer must not misread a
/// file it is about to extend, so by default parsing is strict and anything malformed is `nil`. The importer takes what
/// it can from a file it only reads, so with `lenient` an array or dictionary that is truncated or breaks off keeps
/// what it read before the fault, a hex string skips stray bytes, an unterminated string keeps what it read, and a
/// delimiter that cannot start a value is stepped over (and still answers `nil`), so a caller looping for values moves
/// on.
package struct PDFObjectParser {
    /// Deeper nesting than this is refused, so a hostile file cannot overflow the stack.
    package static let maxDepth = 64

    package let bytes: [UInt8]
    package var pos: Int
    private let lenient: Bool

    package init(_ bytes: [UInt8], at pos: Int = 0, lenient: Bool = false) {
        self.bytes = bytes
        self.pos = max(0, min(pos, bytes.count))
        self.lenient = lenient
    }

    package mutating func skipWhitespaceAndComments() {
        while pos < bytes.count {
            if PDFBytes.isWhitespace(bytes[pos]) {
                pos += 1
            } else if bytes[pos] == PDFBytes.percent {
                while pos < bytes.count, bytes[pos] != PDFBytes.lineFeed, bytes[pos] != PDFBytes.carriageReturn {
                    pos += 1
                }
            } else { return }
        }
    }

    /// The next run of regular characters — a number or a keyword — after any whitespace; empty at a delimiter.
    package mutating func token() -> String {
        skipWhitespaceAndComments()
        let start = pos
        while pos < bytes.count, !PDFBytes.isWhitespace(bytes[pos]), !PDFBytes.isDelimiter(bytes[pos]) {
            pos += 1
        }
        return PDFBytes.string(bytes[start ..< pos])
    }

    /// `N G obj`, or `nil` with the cursor where it was.
    package mutating func parseObjectHeader() -> (number: Int, generation: Int)? {
        let saved = pos
        guard let number = Int(token()), number > 0,
              let generation = Int(token()), (0 ... 65535).contains(generation), token() == "obj"
        else {
            pos = saved
            return nil
        }
        return (number, generation)
    }

    /// The object at the cursor, or `nil` at the end of the bytes or on syntax that does not start one.
    package mutating func parseValue() -> PDFObject? {
        value(depth: 0)
    }

    private mutating func value(depth: Int) -> PDFObject? {
        guard depth < Self.maxDepth else { return nil }
        skipWhitespaceAndComments()
        guard pos < bytes.count else { return nil }
        switch bytes[pos] {
        case PDFBytes.slash: return .name(name())
        case PDFBytes.lparen: return literal().map(PDFObject.string)
        case PDFBytes.lt:
            if pos + 1 < bytes.count, bytes[pos + 1] == PDFBytes.lt { return dictionary(depth: depth) }
            return hexString().map(PDFObject.string)
        case PDFBytes.lbracket: return array(depth: depth)
        default:
            let text = token()
            if text.isEmpty {
                if lenient { pos += 1 }
                return nil
            }
            switch text {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default: break
            }
            if let number = Int(text) {
                let saved = pos
                if number >= 0, let generation = Int(token()), (0 ... 65535).contains(generation), token() == "R" {
                    return .reference(number, generation)
                }
                pos = saved
                return .int(number)
            }
            if let real = Double(text), real.isFinite { return .real(real) }
            return nil
        }
    }

    private mutating func array(depth: Int) -> PDFObject? {
        pos += 1
        var values: [PDFObject] = []
        while true {
            skipWhitespaceAndComments()
            guard pos < bytes.count else { return lenient ? .array(values) : nil }
            if bytes[pos] == PDFBytes.rbracket { pos += 1; return .array(values) }
            guard let item = value(depth: depth + 1) else { return lenient ? .array(values) : nil }
            values.append(item)
        }
    }

    private mutating func dictionary(depth: Int) -> PDFObject? {
        pos += 2
        var values: [String: PDFObject] = [:]
        while true {
            skipWhitespaceAndComments()
            guard pos < bytes.count else { return lenient ? .dictionary(values) : nil }
            if pos + 1 < bytes.count, bytes[pos] == PDFBytes.gt, bytes[pos + 1] == PDFBytes.gt {
                pos += 2; return .dictionary(values)
            }
            guard bytes[pos] == PDFBytes.slash else { return lenient ? .dictionary(values) : nil }
            let key = name()
            guard let item = value(depth: depth + 1) else { return lenient ? .dictionary(values) : nil }
            values[key] = item
        }
    }

    /// A name at the cursor's `/`, its `#XX` escapes decoded.
    private mutating func name() -> String {
        pos += 1
        var value: [UInt8] = []
        while pos < bytes.count, !PDFBytes.isWhitespace(bytes[pos]), !PDFBytes.isDelimiter(bytes[pos]) {
            if bytes[pos] == PDFBytes.hash, pos + 2 < bytes.count,
               let high = PDFBytes.hexValue(bytes[pos + 1]), let low = PDFBytes.hexValue(bytes[pos + 2])
            {
                value.append(high * 16 + low); pos += 3
            } else { value.append(bytes[pos]); pos += 1 }
        }
        return PDFBytes.latin1(value)
    }

    /// A hex string at the cursor's `<`. Whitespace between digits is allowed; an odd final digit is padded with 0.
    private mutating func hexString() -> [UInt8]? {
        pos += 1
        var value: [UInt8] = []
        var high: UInt8?
        while pos < bytes.count {
            let byte = bytes[pos]; pos += 1
            if byte == PDFBytes.gt {
                if let high { value.append(high * 16) }
                return value
            }
            guard let nibble = PDFBytes.hexValue(byte) else {
                if PDFBytes.isWhitespace(byte) || lenient { continue }
                return nil
            }
            if let first = high { value.append(first * 16 + nibble); high = nil } else { high = nibble }
        }
        guard lenient else { return nil }
        if let high { value.append(high * 16) }
        return value
    }

    /// A literal string at the cursor's `(`: balanced parentheses, the escapes of ISO 32000-1 §7.3.4.2, and an
    /// unescaped end-of-line read as one line feed.
    private mutating func literal() -> [UInt8]? {
        pos += 1
        var nesting = 1
        var value: [UInt8] = []
        while pos < bytes.count {
            var byte = bytes[pos]; pos += 1
            if byte == PDFBytes.backslash {
                guard pos < bytes.count else { return lenient ? value : nil }
                byte = bytes[pos]; pos += 1
                switch byte {
                case 0x6E: value.append(PDFBytes.lineFeed)
                case 0x72: value.append(PDFBytes.carriageReturn)
                case 0x74: value.append(PDFBytes.tab)
                case 0x62: value.append(0x08)
                case 0x66: value.append(PDFBytes.formFeed)
                case PDFBytes.lineFeed: break
                case PDFBytes.carriageReturn: if pos < bytes.count, bytes[pos] == PDFBytes.lineFeed { pos += 1 }
                case 0x30 ... 0x37:
                    var octal = Int(byte - 0x30)
                    for _ in 0 ..< 2 {
                        if pos < bytes.count, PDFBytes.isOctalDigit(bytes[pos]) {
                            octal = octal * 8 + Int(bytes[pos] - 0x30); pos += 1
                        } else { break }
                    }
                    value.append(UInt8(truncatingIfNeeded: octal))
                default: value.append(byte)
                }
            } else if byte == PDFBytes.lparen {
                nesting += 1
                value.append(byte)
            } else if byte == PDFBytes.rparen {
                nesting -= 1
                if nesting == 0 { return value }
                value.append(byte)
            } else if byte == PDFBytes.carriageReturn {
                if pos < bytes.count, bytes[pos] == PDFBytes.lineFeed { pos += 1 }
                value.append(PDFBytes.lineFeed)
            } else { value.append(byte) }
        }
        return lenient ? value : nil
    }
}
