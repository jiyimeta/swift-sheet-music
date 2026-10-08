import SheetMusicFoundation

/// Byte classes and small byte-string helpers for PDF syntax, shared by the object parser here, the importer's
/// content-stream tokenizer and the incremental writer. PDF is a byte-oriented format, so all of it works on
/// `[UInt8]`.
package enum PDFBytes {
    package static let tab: UInt8 = 0x09
    package static let lineFeed: UInt8 = 0x0A
    package static let formFeed: UInt8 = 0x0C
    package static let carriageReturn: UInt8 = 0x0D
    package static let space: UInt8 = 0x20
    package static let percent: UInt8 = 0x25
    package static let lparen: UInt8 = 0x28
    package static let rparen: UInt8 = 0x29
    package static let plus: UInt8 = 0x2B
    package static let minus: UInt8 = 0x2D
    package static let period: UInt8 = 0x2E
    package static let slash: UInt8 = 0x2F
    package static let lt: UInt8 = 0x3C
    package static let gt: UInt8 = 0x3E
    package static let lbracket: UInt8 = 0x5B
    package static let backslash: UInt8 = 0x5C
    package static let rbracket: UInt8 = 0x5D
    package static let lbrace: UInt8 = 0x7B
    package static let rbrace: UInt8 = 0x7D
    package static let hash: UInt8 = 0x23

    /// PDF whitespace: NUL, TAB, LF, FF, CR, SPACE.
    package static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x00 || byte == tab || byte == lineFeed || byte == formFeed || byte == carriageReturn || byte == space
    }

    /// PDF delimiter characters: `( ) < > [ ] { } / %`.
    package static func isDelimiter(_ byte: UInt8) -> Bool {
        byte == lparen || byte == rparen || byte == lt || byte == gt
            || byte == lbracket || byte == rbracket || byte == lbrace || byte == rbrace
            || byte == slash || byte == percent
    }

    package static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    package static func isOctalDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x37
    }

    /// A byte that may begin a numeric token (`0-9`, `+`, `-`, `.`).
    package static func isNumberStart(_ byte: UInt8) -> Bool {
        isDigit(byte) || byte == plus || byte == minus || byte == period
    }

    package static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30 ... 0x39: byte - 0x30
        case 0x41 ... 0x46: byte - 0x41 + 10
        case 0x61 ... 0x66: byte - 0x61 + 10
        default: nil
        }
    }

    /// Lossy UTF-8 decode of a byte run (invalid sequences become U+FFFD), for keywords and numeric tokens, which are
    /// ASCII.
    package static func string<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        // swiftlint:disable:next non_optional_string_data_conversion optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }

    /// One Unicode scalar per byte. Names decode this way, so every byte of a name survives — the incremental writer
    /// writes back the name it read — and a name in a content stream equals the same name as a dictionary key.
    package static func latin1(_ bytes: [UInt8]) -> String {
        String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
    }

    /// Does `pattern` occur in `bytes` starting exactly at `pos`?
    package static func matches(_ pattern: [UInt8], _ bytes: [UInt8], _ pos: Int) -> Bool {
        guard pos >= 0, pos + pattern.count <= bytes.count else {
            return false
        }
        for offset in 0 ..< pattern.count where bytes[pos + offset] != pattern[offset] {
            return false
        }
        return true
    }

    /// First index `>= from` where `pattern` occurs, or `nil`.
    package static func firstIndex(of pattern: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else {
            return nil
        }
        let last = bytes.count - pattern.count
        var index = max(0, from)
        while index <= last {
            if matches(pattern, bytes, index) {
                return index
            }
            index += 1
        }
        return nil
    }

    // MARK: - Writing

    /// Preserve a real's precision, expanding Swift's exponent notation into PDF decimal syntax.
    package static func decimal(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        let text = String(value)
        let parts = text.lowercased().split(separator: "e")
        guard parts.count == 2, let exponent = Int(parts[1]) else {
            return text.contains(".") ? text : text + ".0"
        }
        let mantissa = String(parts[0])
        let negative = mantissa.hasPrefix("-")
        let unsigned = negative ? String(mantissa.dropFirst()) : mantissa
        let digits = unsigned.filter { $0 != "." }
        let integerCount = unsigned.split(separator: ".")[0].count
        let point = integerCount + exponent
        let sign = negative ? "-" : ""
        if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
        if point >= digits.count {
            return sign + digits + String(repeating: "0", count: point - digits.count) + ".0"
        }
        return sign + digits.prefix(point) + "." + digits.dropFirst(point)
    }

    package static func hex(_ byte: UInt8) -> String {
        let text = String(byte, radix: 16, uppercase: true)
        return text.count == 1 ? "0" + text : text
    }

    /// A name as PDF syntax, from its `latin1` form: every byte outside the regular printable range is `#`-escaped.
    package static func name(_ value: String) -> String {
        "/" + value.unicodeScalars.map { scalar in
            let byte = UInt8(truncatingIfNeeded: scalar.value)
            return (33 ... 126).contains(byte) && byte != hash && !isDelimiter(byte)
                ? String(Unicode.Scalar(byte)) : "#" + hex(byte)
        }.joined()
    }
}
