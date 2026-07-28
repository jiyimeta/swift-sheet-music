import Foundation

/// A simple font's 1-byte CHARACTER CODE → the TEXT it stands for.
///
/// The music half of this question is `GlyphClassifier`'s cascade; this is
/// the text half, and until now it did not exist: every byte no tier
/// classified was read as Latin-1, one byte one scalar.
///
/// Measured on the real Finale PDFs (`~/Documents/Scores_pdf`, 4 files):
/// their Latin text fonts — `TimesNewRomanPSMT`, `TimesNewRomanPS-BoldMT`,
/// `TimesNewRomanPS-ItalicMT` — declare `/Encoding /MacRomanEncoding` and
/// carry NO `/ToUnicode`, so every code above 0x7F decoded wrong: 0xD5 is
/// `’` in the file and came out `Õ`, 0xC9 is `…` and came out `É`. ASCII
/// was never affected, which is why the damage stayed invisible in the
/// MuseScore corpus (whose fonts are all Identity-H with a proper CMap and
/// never reach this path at all).
///
/// The two sources are consulted in the order PDF 32000-1 gives them:
/// `/Encoding /Differences` names a code's glyph and OVERRIDES the base
/// encoding for that code; whatever `Differences` does not name is governed
/// by the declared base encoding.
struct SimpleFontTextDecoder {
    private let differences: [UInt32: String]
    private let baseEncoding: String

    /// nil when the font declares nothing this can read — no `/Differences`
    /// and no base encoding `SimpleFontEncoding` models. The caller then
    /// keeps its legacy whole-run decode, which matters most for a Type0
    /// font declaring `Identity-H`: those codes are 2 bytes, so decoding
    /// them one byte at a time would be worse than the status quo, not
    /// better.
    init?(differences: [UInt32: String], baseEncoding: String) {
        guard !differences.isEmpty || SimpleFontEncoding.models(baseEncoding: baseEncoding)
        else { return nil }
        self.differences = differences
        self.baseEncoding = baseEncoding
    }

    /// The text `code` stands for, or nil when neither source can say.
    func text(code: UInt32) -> String? {
        if let name = differences[code], let text = AdobeGlyphList.text(forGlyphName: name) {
            return text
        }
        return SimpleFontEncoding.scalar(code: code, baseEncoding: baseEncoding).map(String.init)
    }

    /// Decode a whole show-string operand.
    ///
    /// A code neither source answers keeps its raw byte — the exact reading
    /// every caller had before this type existed — so an encoding this does
    /// not model can only ever add information, never drop a character.
    func decode(_ bytes: [UInt8]) -> String {
        var out = ""
        for byte in bytes {
            if let text = text(code: UInt32(byte)) {
                out += text
            } else {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            }
        }
        return out
    }
}
