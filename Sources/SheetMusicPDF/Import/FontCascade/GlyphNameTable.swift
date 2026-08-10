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
///
/// A few names are shared with ORDINARY TEXT — see `textAmbiguousTable` — and
/// are only consulted when the caller has independent evidence that the font
/// is a music font.
enum GlyphNameTable {
    /// - Parameter allowingTextAmbiguousNames: consult `textAmbiguousTable`
    ///   too. Pass true only for a font already known to be a music font;
    ///   see that table's doc comment.
    static func semantic(
        glyphName raw: String, allowingTextAmbiguousNames: Bool = false,
    ) -> SMuFLSemantic? {
        guard !raw.isEmpty else { return nil }
        // "uniE0A4" / "uE0A4" carry the codepoint directly.
        if let cp = codepointFromUniName(raw) {
            let s = PDFImporter.smuflSemantic(codepoint: cp)
            if case .unknown = s { return nil }
            return s
        }
        let key = raw.lowercased()
        if let hit = table[key] { return hit }
        return allowingTextAmbiguousNames ? textAmbiguousTable[key] : nil
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
        // `repeatdots` is the pair as one glyph, `repeatdot` a single
        // dot — MuseScore engraves a repeat barline as two of the
        // latter, so a name-tier font that spells them out needs both.
        "repeatdots": .repeatBarlineDots, "repeatdot": .repeatBarlineDots,
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
        .merging(smuflTimeSignatureDigitNames) { a, _ in a }

    /// Names a MUSIC font may use that an ordinary TEXT font uses too.
    ///
    /// `zero`…`nine` are the Adobe Glyph List's standard names for the ASCII
    /// digits, so `/Encoding /Differences [48 /zero /one /two …]` is how TeX,
    /// Word, Finale and Sibelius all re-encode the digits of a plain text
    /// font. Read unconditionally they would turn every such digit into a
    /// `.timeSignatureDigit`, which invents time signatures, invents
    /// multi-measure-rest counts (`mmRestCount` reads exactly these), and
    /// deletes the digits from the title / lyric text they belong to.
    ///
    /// No corpus PDF can catch this: every corpus font's `/Differences` is
    /// empty. `GlyphClassifier` decides when to consult this table — see
    /// `acceptsTextAmbiguousNames`.
    private static let textAmbiguousTable: [String: SMuFLSemantic] = {
        var out: [String: SMuFLSemantic] = [:]
        for (i, word) in aglDigitNames.enumerated() {
            out[word] = .timeSignatureDigit(i)
        }
        return out
    }()

    /// Adobe Glyph List names for the ASCII digits, index = value.
    private static let aglDigitNames = [
        "zero", "one", "two", "three", "four",
        "five", "six", "seven", "eight", "nine",
    ]

    /// "timeSig0"…"timeSig9" — SMuFL's own names, which no text font uses.
    private static let smuflTimeSignatureDigitNames: [String: SMuFLSemantic] = {
        var out: [String: SMuFLSemantic] = [:]
        for i in 0 ... 9 {
            out["timesig\(i)"] = .timeSignatureDigit(i)
        }
        return out
    }()

    /// True when `name` identifies a glyph ONLY a music font has — i.e. it
    /// resolves without needing `textAmbiguousTable`. `GlyphClassifier` uses
    /// this to decide whether a font's own encoding vouches for it.
    static func isUnambiguousMusicName(_ name: String) -> Bool {
        semantic(glyphName: name, allowingTextAmbiguousNames: false) != nil
    }
}
