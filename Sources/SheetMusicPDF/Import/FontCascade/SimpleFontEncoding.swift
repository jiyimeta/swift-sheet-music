import Foundation

/// A simple font's CHARACTER CODE → Unicode scalar, through the `/Encoding`
/// base encoding the PDF declares.
///
/// A simple font shows 1-byte codes that are NOT glyph IDs and NOT Unicode:
/// they index the font's encoding. Measured on real Finale output, that
/// indirection is the whole reason Tier 4 saw nothing — the bytes (207, 206,
/// 250, 228, …) are `MacRomanEncoding` codes, and the subsetted TrueType
/// keeps a UNICODE cmap, so the byte only reaches an outline after being
/// decoded to its scalar first (0xCF → U+0153 → glyph 12).
enum SimpleFontEncoding {
    /// Decode `code` under the base encoding named by `/Encoding` (or
    /// `/Encoding /BaseEncoding`). Returns nil for a code the encoding
    /// leaves undefined, and for an encoding this does not model.
    static func scalar(code: UInt32, baseEncoding: String) -> Unicode.Scalar? {
        guard let encoding = stringEncoding(for: baseEncoding) else { return nil }
        return scalar(code: code, using: encoding, isMacRoman: encoding == .macOSRoman)
    }

    /// The encodings to TRY, in order, for a font that declares no usable
    /// base encoding. A producer that omits `/Encoding` means "the font's
    /// built-in encoding", which this side cannot read — but the two
    /// candidates below are what real producers actually use, and a wrong
    /// guess simply fails to resolve a glyph rather than resolving a wrong
    /// one, because each candidate scalar is then required to hit the
    /// font's own cmap.
    static let fallbackEncodings: [String] = ["MacRomanEncoding", "WinAnsiEncoding"]

    private static func stringEncoding(for baseEncoding: String) -> String.Encoding? {
        switch baseEncoding {
        case "MacRomanEncoding": .macOSRoman
        case "WinAnsiEncoding": .windowsCP1252
        // `StandardEncoding` agrees with ASCII over 0x20-0x7E, which is the
        // part any cmap lookup can use; its upper half is a typographic set
        // Latin-1 does not match, but a wrong scalar there just fails to
        // resolve. `MacExpertEncoding` is a small-caps / old-style-figure
        // set with no Latin-1 correspondence at all — deliberately absent
        // rather than approximated.
        case "StandardEncoding": .isoLatin1
        default: nil
        }
    }

    private static func scalar(
        code: UInt32, using encoding: String.Encoding, isMacRoman: Bool,
    ) -> Unicode.Scalar? {
        guard code <= 0xFF else { return nil }
        // PDF's MacRomanEncoding differs from Mac OS Roman in exactly one
        // place: 0xDB is `currency` (U+00A4) in the PDF encoding and EURO
        // SIGN (U+20AC) in Mac OS Roman. Nothing else in the two tables
        // disagrees.
        if isMacRoman, code == 0xDB { return Unicode.Scalar(0x00A4) }
        let byte = UInt8(code)
        guard let decoded = String(bytes: [byte], encoding: encoding),
              let scalar = decoded.unicodeScalars.first,
              decoded.unicodeScalars.count == 1
        else { return nil }
        return scalar
    }
}
