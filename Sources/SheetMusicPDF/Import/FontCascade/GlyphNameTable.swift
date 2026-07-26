import Foundation
import SheetMusicCore

/// Tier 2 of the classification cascade: map a glyph NAME to a semantic.
///
/// Names come from `/Encoding /Differences` or the embedded font's own charset.
/// They survive more often than a usable SMuFL encoding does, and — unlike
/// codepoints — are stable across font vendors, because SMuFL standardizes the
/// names even where legacy fonts predate the encoding.
///
/// Returns nil for an unrecognized name so `GlyphClassifier` falls through to
/// Tier 4 shape matching rather than guessing.
enum GlyphNameTable {
    static func semantic(glyphName raw: String) -> SMuFLSemantic? {
        guard !raw.isEmpty else { return nil }
        // "uniE0A4" / "uE0A4" carry the codepoint directly.
        if let cp = codepointFromUniName(raw) {
            let s = PDFImporter.smuflSemantic(codepoint: cp)
            if case .unknown = s { return nil }
            return s
        }
        let key = raw.lowercased()
        return table[key]
    }

    /// "uniE0A4" / "uE0A4" → 0xE0A4.
    private static func codepointFromUniName(_ name: String) -> UInt32? {
        let hex: Substring
        if name.hasPrefix("uni"), name.count == 7 {
            hex = name.dropFirst(3)
        } else if name.hasPrefix("u"), name.count >= 5, name.count <= 7,
                  name.dropFirst().allSatisfy(\.isHexDigit)
        {
            hex = name.dropFirst()
        } else {
            return nil
        }
        return UInt32(hex, radix: 16)
    }

    /// Lowercased name → semantic. Canonical SMuFL names first, then the
    /// legacy PostScript names used by pre-SMuFL music fonts.
    private static let table: [String: SMuFLSemantic] = [
        // Canonical SMuFL.
        "brace": .brace,
        "gclef": .clefG, "gclef8vb": .clefG8vb, "gclef8va": .clefG8va,
        "gclef15ma": .clefG15ma, "gclef15mb": .clefG15mb,
        "fclef": .clefF, "fclef8vb": .clefF8vb, "fclef8va": .clefF8va,
        "fclef15ma": .clefF15ma, "fclef15mb": .clefF15mb,
        "cclef": .clefC, "unpitchedpercussionclef1": .clefPercussion,
        "noteheaddoublewhole": .noteheadDoubleWhole,
        "noteheadwhole": .noteheadWhole,
        "noteheadhalf": .noteheadHalf,
        "noteheadblack": .noteheadBlack,
        "noteheadxwhole": .noteheadXWhole,
        "noteheadxhalf": .noteheadXHalf,
        "noteheadxblack": .noteheadXBlack,
        "noteheadvoidwithx": .noteheadXBlack,
        "noteshapediamondblack": .noteheadBlack,
        "augmentationdot": .augmentationDot,
        "flag8thup": .flag8thUp, "flag8thdown": .flag8thDown,
        "flag16thup": .flag16thUp, "flag16thdown": .flag16thDown,
        "flag32ndup": .flag32ndUp, "flag32nddown": .flag32ndDown,
        "flag64thup": .flag64thUp, "flag64thdown": .flag64thDown,
        "accidentalflat": .accidentalFlat,
        "accidentalnatural": .accidentalNatural,
        "accidentalsharp": .accidentalSharp,
        "accidentaldoublesharp": .accidentalDoubleSharp,
        "accidentaldoubleflat": .accidentalDoubleFlat,
        "restwhole": .rest(.whole), "resthalf": .rest(.half),
        "restquarter": .rest(.quarter), "rest8th": .rest(.eighth),
        "rest16th": .rest(.sixteenth), "rest32nd": .rest(.thirtySecond),
        "rest64th": .rest(.sixtyFourth),
        "timesigcommon": .timeSignatureCommon,
        "timesigcutcommon": .timeSignatureCutTime,
        "staff5lines": .staff5Lines,
        "repeatdots": .repeatBarlineDots,
        "segno": .segno, "coda": .coda,
        "fermataabove": .fermata, "fermatabelow": .fermata,
        // Legacy PostScript names (Maestro / Petrucci / Opus / Sonata family).
        "wholerest": .rest(.whole), "halfrest": .rest(.half),
        "quarterrest": .rest(.quarter), "eighthrest": .rest(.eighth),
        "sixteenthrest": .rest(.sixteenth),
        "thirtysecondrest": .rest(.thirtySecond),
        "sixtyfourthrest": .rest(.sixtyFourth),
        "sharp": .accidentalSharp, "flat": .accidentalFlat,
        "natural": .accidentalNatural,
        "doublesharp": .accidentalDoubleSharp,
        "doubleflat": .accidentalDoubleFlat,
        "trebleclef": .clefG, "bassclef": .clefF, "altoclef": .clefC,
        "notehead": .noteheadBlack,
        "halfnotehead": .noteheadHalf, "wholenotehead": .noteheadWhole,
        "dot": .augmentationDot,
    ]
        .merging(timeSignatureDigitNames) { a, _ in a }

    /// "zero"…"nine" and "timeSig0"…"timeSig9".
    private static let timeSignatureDigitNames: [String: SMuFLSemantic] = {
        let words = [
            "zero",
            "one",
            "two",
            "three",
            "four",
            "five",
            "six",
            "seven",
            "eight",
            "nine",
        ]
        var out: [String: SMuFLSemantic] = [:]
        for (i, w) in words.enumerated() {
            out[w] = .timeSignatureDigit(i)
            out["timesig\(i)"] = .timeSignatureDigit(i)
        }
        return out
    }()
}
