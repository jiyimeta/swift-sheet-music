#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Recursive-descent parser for PDF object syntax over a `[UInt8]` buffer.
///
/// Parses one `PDFObject` starting at `pos`, advancing the cursor. Handles
/// numbers, names, literal/hex strings, arrays, dictionaries, booleans,
/// `null`, and indirect references (`N G R`). Stream detection (the `stream`
/// … `endstream` payload that may follow a dictionary) lives in
/// `PDFReaderDocument`, which parses the dictionary here and then inspects
/// the following bytes.
struct PDFObjectParser {
    let bytes: [UInt8]
    var pos: Int

    init(_ bytes: [UInt8], at pos: Int = 0) {
        self.bytes = bytes
        self.pos = pos
    }

    /// Parse the next object at the cursor, or `nil` at end / on a stray
    /// delimiter (one byte is consumed in the latter case to avoid stalling).
    mutating func parseObject() -> PDFObject? {
        skipWhitespaceAndComments()
        guard pos < bytes.count else {
            return nil
        }
        let c = bytes[pos]
        switch c {
        case PDFBytes.slash:
            return .name(parseNameString())
        case PDFBytes.lparen:
            return .string(parseLiteralString())
        case PDFBytes.lt:
            if pos + 1 < bytes.count, bytes[pos + 1] == PDFBytes.lt {
                return parseDictionary()
            }
            return .string(parseHexString())
        case PDFBytes.lbracket:
            return parseArray()
        default:
            let token = readRegularRun()
            if token.isEmpty {
                pos += 1 // stray delimiter: consume to make progress
                return nil
            }
            return interpret(token)
        }
    }

    // MARK: - Cursor helpers

    mutating func skipWhitespaceAndComments() {
        while pos < bytes.count {
            let c = bytes[pos]
            if PDFBytes.isWhitespace(c) {
                pos += 1
            } else if c == PDFBytes.percent {
                while pos < bytes.count,
                      bytes[pos] != PDFBytes.lineFeed,
                      bytes[pos] != PDFBytes.carriageReturn
                {
                    pos += 1
                }
            } else {
                break
            }
        }
    }

    /// Read a run of "regular" characters (non-whitespace, non-delimiter):
    /// numbers and keywords such as `true`, `null`, `R`.
    mutating func readRegularRun() -> String {
        var out = [UInt8]()
        while pos < bytes.count {
            let c = bytes[pos]
            if PDFBytes.isWhitespace(c) || PDFBytes.isDelimiter(c) {
                break
            }
            out.append(c)
            pos += 1
        }
        return PDFBytes.string(out)
    }

    // MARK: - Token interpretation

    private mutating func interpret(_ token: String) -> PDFObject? {
        switch token {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null": return .null
        default: break
        }
        guard let first = token.utf8.first, PDFBytes.isNumberStart(first) else {
            return nil // unknown keyword (e.g. a stray `obj` / `endobj`)
        }
        if let n = Int(token) {
            return referenceOrInt(n)
        }
        if let d = Double(token) {
            return .real(d)
        }
        return nil
    }

    /// After reading integer `n`, peek for `G R` to form an indirect
    /// reference; otherwise the cursor is restored and `.int(n)` returned.
    private mutating func referenceOrInt(_ n: Int) -> PDFObject {
        let save = pos
        skipWhitespaceAndComments()
        let genToken = readRegularRun()
        if !genToken.contains("."), let g = Int(genToken) {
            skipWhitespaceAndComments()
            if readRegularRun() == "R" {
                return .reference(n, g)
            }
        }
        pos = save
        return .int(n)
    }

    // MARK: - Composite parsers

    private mutating func parseArray() -> PDFObject {
        pos += 1 // '['
        var items = [PDFObject]()
        while true {
            skipWhitespaceAndComments()
            guard pos < bytes.count else {
                break
            }
            if bytes[pos] == PDFBytes.rbracket {
                pos += 1
                break
            }
            guard let obj = parseObject() else {
                break
            }
            items.append(obj)
        }
        return .array(items)
    }

    private mutating func parseDictionary() -> PDFObject {
        pos += 2 // '<<'
        var dict = [String: PDFObject]()
        while true {
            skipWhitespaceAndComments()
            guard pos < bytes.count else {
                break
            }
            if bytes[pos] == PDFBytes.gt, pos + 1 < bytes.count, bytes[pos + 1] == PDFBytes.gt {
                pos += 2 // '>>'
                break
            }
            guard bytes[pos] == PDFBytes.slash else {
                break // malformed dictionary body
            }
            let key = parseNameString()
            skipWhitespaceAndComments()
            guard let value = parseObject() else {
                break
            }
            dict[key] = value
        }
        return .dictionary(dict)
    }

    // MARK: - Scalar parsers

    /// Parse a name (`/Name`) into its string, decoding `#XX` hex escapes.
    private mutating func parseNameString() -> String {
        pos += 1 // '/'
        var out = [UInt8]()
        while pos < bytes.count {
            let c = bytes[pos]
            if PDFBytes.isWhitespace(c) || PDFBytes.isDelimiter(c) {
                break
            }
            if c == PDFBytes.hash, pos + 2 < bytes.count,
               let hi = PDFBytes.hexValue(bytes[pos + 1]),
               let lo = PDFBytes.hexValue(bytes[pos + 2])
            {
                out.append(UInt8(hi * 16 + lo))
                pos += 3
                continue
            }
            out.append(c)
            pos += 1
        }
        return PDFBytes.string(out)
    }

    private mutating func parseLiteralString() -> [UInt8] {
        pos += 1 // '('
        var out = [UInt8]()
        var depth = 1
        while pos < bytes.count {
            let c = bytes[pos]
            pos += 1
            if c == PDFBytes.backslash {
                appendEscape(into: &out)
            } else if c == PDFBytes.lparen {
                depth += 1
                out.append(c)
            } else if c == PDFBytes.rparen {
                depth -= 1
                if depth == 0 {
                    break
                }
                out.append(c)
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// Handle the byte(s) after a backslash inside a literal string.
    private mutating func appendEscape(into out: inout [UInt8]) {
        guard pos < bytes.count else {
            return
        }
        let e = bytes[pos]
        pos += 1
        switch e {
        case 0x6E: out.append(PDFBytes.lineFeed) // \n
        case 0x72: out.append(PDFBytes.carriageReturn) // \r
        case 0x74: out.append(PDFBytes.tab) // \t
        case 0x62: out.append(0x08) // \b
        case 0x66: out.append(PDFBytes.formFeed) // \f
        case PDFBytes.lparen: out.append(PDFBytes.lparen)
        case PDFBytes.rparen: out.append(PDFBytes.rparen)
        case PDFBytes.backslash: out.append(PDFBytes.backslash)
        case PDFBytes.lineFeed: break // line continuation
        case PDFBytes.carriageReturn:
            if pos < bytes.count, bytes[pos] == PDFBytes.lineFeed {
                pos += 1 // CRLF continuation
            }
        case 0x30 ... 0x37: // octal \ddd (first digit already in `e`)
            var value = Int(e - 0x30)
            var count = 1
            while count < 3, pos < bytes.count, PDFBytes.isOctalDigit(bytes[pos]) {
                value = value * 8 + Int(bytes[pos] - 0x30)
                pos += 1
                count += 1
            }
            out.append(UInt8(value & 0xFF))
        default:
            out.append(e) // unknown escape: keep the literal byte
        }
    }

    private mutating func parseHexString() -> [UInt8] {
        pos += 1 // '<'
        var nibbles = [Int]()
        while pos < bytes.count {
            let c = bytes[pos]
            pos += 1
            if c == PDFBytes.gt {
                break
            }
            if let v = PDFBytes.hexValue(c) {
                nibbles.append(v)
            }
        }
        if nibbles.count % 2 == 1 {
            nibbles.append(0) // odd trailing digit padded with 0
        }
        var out = [UInt8]()
        out.reserveCapacity(nibbles.count / 2)
        var i = 0
        while i < nibbles.count {
            out.append(UInt8((nibbles[i] << 4) | nibbles[i + 1]))
            i += 2
        }
        return out
    }
}
