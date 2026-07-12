#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Byte-classification helpers and small keyword-search utilities shared by
/// the PDF object lexer, the document parser, and the content-stream
/// tokenizer. PDF is a byte-oriented format, so all scanning works on
/// `[UInt8]` rather than `String`.
enum PDFBytes {
    static let tab: UInt8 = 0x09
    static let lineFeed: UInt8 = 0x0A
    static let formFeed: UInt8 = 0x0C
    static let carriageReturn: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let percent: UInt8 = 0x25
    static let lparen: UInt8 = 0x28
    static let rparen: UInt8 = 0x29
    static let plus: UInt8 = 0x2B
    static let minus: UInt8 = 0x2D
    static let period: UInt8 = 0x2E
    static let slash: UInt8 = 0x2F
    static let lt: UInt8 = 0x3C
    static let gt: UInt8 = 0x3E
    static let lbracket: UInt8 = 0x5B
    static let backslash: UInt8 = 0x5C
    static let rbracket: UInt8 = 0x5D
    static let lbrace: UInt8 = 0x7B
    static let rbrace: UInt8 = 0x7D
    static let hash: UInt8 = 0x23

    /// PDF whitespace: NUL, TAB, LF, FF, CR, SPACE.
    static func isWhitespace(_ c: UInt8) -> Bool {
        c == 0x00 || c == tab || c == lineFeed || c == formFeed || c == carriageReturn || c == space
    }

    /// PDF delimiter characters: `( ) < > [ ] { } / %`.
    static func isDelimiter(_ c: UInt8) -> Bool {
        c == lparen || c == rparen || c == lt || c == gt
            || c == lbracket || c == rbracket || c == lbrace || c == rbrace
            || c == slash || c == percent
    }

    static func isDigit(_ c: UInt8) -> Bool {
        c >= 0x30 && c <= 0x39
    }

    static func isOctalDigit(_ c: UInt8) -> Bool {
        c >= 0x30 && c <= 0x37
    }

    /// A byte that may begin a numeric token (`0-9`, `+`, `-`, `.`).
    static func isNumberStart(_ c: UInt8) -> Bool {
        isDigit(c) || c == plus || c == minus || c == period
    }

    /// Lossy UTF-8 decode of a byte run (invalid sequences become U+FFFD).
    /// Used for PDF names / keywords / numeric tokens, which are ASCII.
    static func string<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        // swiftlint:disable:next non_optional_string_data_conversion optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }

    static func hexValue(_ c: UInt8) -> Int? {
        switch c {
        case 0x30 ... 0x39: return Int(c - 0x30)
        case 0x41 ... 0x46: return Int(c - 0x41 + 10)
        case 0x61 ... 0x66: return Int(c - 0x61 + 10)
        default: return nil
        }
    }

    /// Does `pattern` occur in `bytes` starting exactly at `pos`?
    static func matches(_ pattern: [UInt8], _ bytes: [UInt8], _ pos: Int) -> Bool {
        guard pos >= 0, pos + pattern.count <= bytes.count else {
            return false
        }
        for k in 0 ..< pattern.count where bytes[pos + k] != pattern[k] {
            return false
        }
        return true
    }

    /// First index `>= from` where `pattern` occurs, or `nil`.
    static func firstIndex(of pattern: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else {
            return nil
        }
        let last = bytes.count - pattern.count
        var i = max(0, from)
        while i <= last {
            if matches(pattern, bytes, i) {
                return i
            }
            i += 1
        }
        return nil
    }
}
