// Note on the `optional_data_string_conversion` suppressions below:
// `String(decoding:as: UTF8.self)` is deliberate. The buffer is validated as
// UTF-8 once before scanning starts (`firstInvalidUTF8`), so the non-failable
// initializer cannot silently substitute replacement characters, and the inputs
// are `ArraySlice<UInt8>` rather than `Data` — the failable
// `String(bytes:encoding:)` the rule asks for lives in Foundation, which this
// target exists to stop depending on.

/// UTF-8 byte cursor with the lexical pieces `XMLTreeParser` needs.
///
/// Scanning bytes rather than `String` keeps the hot loop allocation-free and
/// avoids per-token `String.Index` arithmetic. Every delimiter XML cares about
/// (`<`, `>`, `&`, `;`, quotes, `/`) is ASCII, and UTF-8 never encodes an ASCII
/// byte inside a multi-byte sequence, so byte-level scanning is safe.
struct XMLScanner {
    let bytes: [UInt8]
    var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        // A UTF-8 BOM is not part of the document.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            index = 3
        }
    }

    var isAtEnd: Bool {
        index >= bytes.count
    }

    /// Index of the first byte that breaks UTF-8 well-formedness, or nil.
    ///
    /// The whole buffer is checked once up front so that every later slice can
    /// use `String(decoding:as:)` without it silently substituting replacement
    /// characters — Foundation's parser rejected invalid UTF-8, and so must
    /// this one. (`String(validating:as:)` would do the job but is macOS 15+.)
    static func firstInvalidUTF8(in bytes: [UInt8]) -> Int? {
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            let width: Int
            var lowerBound: UInt8 = 0x80
            var upperBound: UInt8 = 0xBF
            switch byte {
            case 0x00 ... 0x7F: width = 1
            case 0xC2 ... 0xDF: width = 2
            case 0xE0: width = 3; lowerBound = 0xA0
            case 0xE1 ... 0xEC, 0xEE, 0xEF: width = 3
            case 0xED: width = 3; upperBound = 0x9F
            case 0xF0: width = 4; lowerBound = 0x90
            case 0xF1 ... 0xF3: width = 4
            case 0xF4: width = 4; upperBound = 0x8F
            default: return index
            }
            guard index + width <= bytes.count else { return index }
            for offset in 1 ..< max(width, 1) {
                let continuation = bytes[index + offset]
                let low = offset == 1 ? lowerBound : 0x80
                let high = offset == 1 ? upperBound : 0xBF
                guard continuation >= low, continuation <= high else { return index + offset }
            }
            index += width
        }
        return nil
    }

    func peek(_ offset: Int = 0) -> UInt8? {
        let target = index + offset
        return target < bytes.count ? bytes[target] : nil
    }

    /// Whether the bytes at the cursor equal `literal`.
    func matches(_ literal: [UInt8]) -> Bool {
        guard index + literal.count <= bytes.count else { return false }
        for offset in literal.indices where bytes[index + offset] != literal[offset] {
            return false
        }
        return true
    }

    mutating func advance(_ count: Int = 1) {
        index = min(index + count, bytes.count)
    }

    mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            advance()
        }
    }

    // MARK: - Errors

    /// Line/column are derived only when something has already gone wrong, so
    /// the happy path carries no position-tracking cost.
    func error(_ message: String, at position: Int? = nil) -> XMLSyntaxError {
        let target = min(position ?? index, bytes.count)
        var line = 1
        var column = 1
        var cursor = 0
        while cursor < target {
            if bytes[cursor] == 0x0A {
                line += 1
                column = 1
            } else {
                column += 1
            }
            cursor += 1
        }
        return XMLSyntaxError(line: line, column: column, message: message)
    }

    // MARK: - Names

    /// XML names are permissive by design here: anything that is not a
    /// delimiter is accepted, which matches what a non-validating parser needs
    /// and keeps prefixed names (`mei:note`) verbatim, as
    /// `shouldProcessNamespaces = false` did.
    mutating func scanName() throws -> String {
        let start = index
        while let byte = peek(), !Self.isNameTerminator(byte) {
            advance()
        }
        guard index > start else {
            throw error("expected an element or attribute name")
        }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes[start ..< index], as: UTF8.self)
    }

    private static func isNameTerminator(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x20, 0x09, 0x0A, 0x0D, // whitespace
             0x2F, // /
             0x3E, // >
             0x3C, // <
             0x3D, // =
             0x22, 0x27: // " '
            return true
        default:
            return false
        }
    }

    // MARK: - References

    /// Decode the reference at the cursor (which must be on `&`) and append it
    /// to `out`. Characters produced this way are exempt from the line-end and
    /// attribute-value normalizations, so callers append them directly.
    mutating func scanReference(into out: inout String) throws {
        let start = index
        advance() // &
        guard let byte = peek() else { throw error("unterminated entity reference", at: start) }

        if byte == 0x23 { // #
            advance()
            let isHex = peek() == 0x78 || peek() == 0x58 // x X
            if isHex { advance() }
            let digitsStart = index
            while let digit = peek(), digit != 0x3B {
                advance()
            }
            guard peek() == 0x3B else {
                throw error("unterminated character reference", at: start)
            }
            // swiftlint:disable:next optional_data_string_conversion
            let text = String(decoding: bytes[digitsStart ..< index], as: UTF8.self)
            guard !text.isEmpty,
                  let value = UInt32(text, radix: isHex ? 16 : 10),
                  let scalar = Unicode.Scalar(value),
                  Self.isValidXMLCharacter(value)
            else {
                throw error("character reference is not a valid XML character", at: start)
            }
            advance() // ;
            out.unicodeScalars.append(scalar)
            return
        }

        let nameStart = index
        while let candidate = peek(), candidate != 0x3B, !Self.isNameTerminator(candidate) {
            advance()
        }
        guard peek() == 0x3B else {
            throw error("unterminated entity reference", at: start)
        }
        // swiftlint:disable:next optional_data_string_conversion
        let name = String(decoding: bytes[nameStart ..< index], as: UTF8.self)
        advance() // ;

        switch name {
        case "amp": out.append("&")
        case "lt": out.append("<")
        case "gt": out.append(">")
        case "quot": out.append("\"")
        case "apos": out.append("'")
        default:
            // The DOCTYPE is skipped wholesale, so locally declared entities
            // are unknown here. No MuseScore or MusicXML writer emits them.
            throw error("undefined entity &\(name);", at: start)
        }
    }

    private static func isValidXMLCharacter(_ value: UInt32) -> Bool {
        value == 0x9 || value == 0xA || value == 0xD
            || (value >= 0x20 && value <= 0xD7FF)
            || (value >= 0xE000 && value <= 0xFFFD)
            || (value >= 0x10000 && value <= 0x10FFFF)
    }

    // MARK: - Raw runs

    /// Append the literal bytes in `range` to `out`. The buffer was validated
    /// as UTF-8 before scanning began, so decoding cannot lose anything here.
    func appendText(_ range: Range<Int>, to out: inout String) {
        guard !range.isEmpty else { return }
        // swiftlint:disable:next optional_data_string_conversion
        out += String(decoding: bytes[range], as: UTF8.self)
    }
}
