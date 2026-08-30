import Foundation
import SheetMusicCore

/// Stable string names for `SMuFLSemantic` cases — the label-format class
/// vocabulary (spec §7.1) and the detector's frozen class table.
///
/// `className(for:)` (`Tests/SheetMusicTests/Helpers/OMRLabelClassNames.swift`,
/// reached back into this table via `@testable import SheetMusicPDF`) is
/// TOTAL: every `SMuFLSemantic` value maps to a name. `semantic(forClassName:)`
/// round-trips every name `className(for:)` can produce, with exactly one
/// deliberate exception: `restOther`, the shared fallback for
/// `.rest(.fraction)` and `.rest(.measure)`. That name discards the
/// duration's parameters, so the reverse direction cannot reconstruct which
/// rest it was and `semantic(forClassName: "restOther")` returns `nil` on
/// purpose — do not turn this into a fabricated duration. Gate P0-G1
/// (Task 6) needs the oracle replay to compare `Score` values exactly; a
/// silent wrong-but-plausible duration would corrupt that gate, while `nil`
/// fails loudly as intended.
///
/// ORDER IS FROZEN: `Training/generate/vocabulary.py` mirrors `detectorTable`
/// 1:1 and COCO category ids are positions in it. Append-only.
///
/// Two rows in `detectorTable` are marked `// UNREACHABLE`, and the marker
/// is load-bearing — `Training/tests/test_vocabulary.py` parses it and
/// asserts it against `vocabulary.UNREACHABLE`. `fine` and `toCoda` have no
/// SMuFL glyph at all (the specification has only `coda` U+E048 and
/// `codaSquare` U+E049); MuseScore engraves both markers as WORDS, so they
/// arrive in the text stream, and `TextGlyph` carries no ink box by design.
/// Nothing can ever emit a detector box for them. They stay in the list
/// because it is append-only, and gate P3c-G3 subtracts them from its
/// denominator rather than reporting a shortfall no run can ever fix.
/// `PDFImporter+Structure` does recover both markers — from that text
/// stream — so the score-level path has them and only the seam-level path
/// cannot.
///
/// FROZEN. `classes` in an exported `model.json` must equal `trainable`
/// exactly, in order — a model whose class 7 means something other than
/// this table's class 7 builds a plausible-looking score out of the wrong
/// symbols, with no crash and no diagnostic. `OMRModelManifest.checkVocabulary`
/// is the gate; this is the reference it checks against.
enum OMRGlyphVocabulary {
    /// (className, semantic) — one row per detector class.
    static let detectorTable: [(className: String, semantic: SMuFLSemantic)] = [
        ("brace", .brace),
        ("noteheadDoubleWhole", .noteheadDoubleWhole),
        ("noteheadWhole", .noteheadWhole),
        ("noteheadHalf", .noteheadHalf),
        ("noteheadBlack", .noteheadBlack),
        ("noteheadXWhole", .noteheadXWhole),
        ("noteheadXHalf", .noteheadXHalf),
        ("noteheadXBlack", .noteheadXBlack),
        ("flag8thUp", .flag8thUp),
        ("flag8thDown", .flag8thDown),
        ("flag16thUp", .flag16thUp),
        ("flag16thDown", .flag16thDown),
        ("flag32ndUp", .flag32ndUp),
        ("flag32ndDown", .flag32ndDown),
        ("flag64thUp", .flag64thUp),
        ("flag64thDown", .flag64thDown),
        ("augmentationDot", .augmentationDot),
        ("restWhole", .rest(.whole)),
        ("restHalf", .rest(.half)),
        ("restQuarter", .rest(.quarter)),
        ("rest8th", .rest(.eighth)),
        ("rest16th", .rest(.sixteenth)),
        ("rest32nd", .rest(.thirtySecond)),
        ("rest64th", .rest(.sixtyFourth)),
        ("clefG", .clefG),
        ("clefG8va", .clefG8va),
        ("clefG8vb", .clefG8vb),
        ("clefG15ma", .clefG15ma),
        ("clefG15mb", .clefG15mb),
        ("clefF", .clefF),
        ("clefF8va", .clefF8va),
        ("clefF8vb", .clefF8vb),
        ("clefF15ma", .clefF15ma),
        ("clefF15mb", .clefF15mb),
        ("clefC", .clefC),
        ("clefPercussion", .clefPercussion),
        ("accidentalSharp", .accidentalSharp),
        ("accidentalFlat", .accidentalFlat),
        ("accidentalNatural", .accidentalNatural),
        ("accidentalDoubleSharp", .accidentalDoubleSharp),
        ("accidentalDoubleFlat", .accidentalDoubleFlat),
        ("timeSig0", .timeSignatureDigit(0)),
        ("timeSig1", .timeSignatureDigit(1)),
        ("timeSig2", .timeSignatureDigit(2)),
        ("timeSig3", .timeSignatureDigit(3)),
        ("timeSig4", .timeSignatureDigit(4)),
        ("timeSig5", .timeSignatureDigit(5)),
        ("timeSig6", .timeSignatureDigit(6)),
        ("timeSig7", .timeSignatureDigit(7)),
        ("timeSig8", .timeSignatureDigit(8)),
        ("timeSig9", .timeSignatureDigit(9)),
        ("timeSigCommon", .timeSignatureCommon),
        ("timeSigCutTime", .timeSignatureCutTime),
        ("repeatBarlineDots", .repeatBarlineDots),
        ("segno", .segno),
        ("coda", .coda),
        ("dalSegno", .dalSegno),
        ("daCapo", .daCapo),
        ("fine", .fine), // UNREACHABLE: no SMuFL glyph, drawn as text
        ("toCoda", .toCoda), // UNREACHABLE: no SMuFL glyph, drawn as text
        ("fermata", .fermata),
        ("dynamic", .dynamic),
        ("articulation", .articulation),
        ("ornament", .ornament),
    ]

    static let detectorVocabulary: [String] = detectorTable.map(\.className)

    private static let semanticByName: [String: SMuFLSemantic] =
        Dictionary(uniqueKeysWithValues: detectorTable.map { ($0.className, $0.semantic) })

    /// The 62 trainable classes, in frozen table order. The model's class
    /// index IS this array's index — `detectorVocabulary` minus the two
    /// UNREACHABLE rows (`fine`, `toCoda`) and the reserved/non-detector
    /// names (`stem`, `staff5Lines`, `restOther`, `unknown*`), none of
    /// which appear in `detectorVocabulary` to begin with.
    static let trainable: [String] = [
        "brace",
        "noteheadDoubleWhole",
        "noteheadWhole",
        "noteheadHalf",
        "noteheadBlack",
        "noteheadXWhole",
        "noteheadXHalf",
        "noteheadXBlack",
        "flag8thUp",
        "flag8thDown",
        "flag16thUp",
        "flag16thDown",
        "flag32ndUp",
        "flag32ndDown",
        "flag64thUp",
        "flag64thDown",
        "augmentationDot",
        "restWhole",
        "restHalf",
        "restQuarter",
        "rest8th",
        "rest16th",
        "rest32nd",
        "rest64th",
        "clefG",
        "clefG8va",
        "clefG8vb",
        "clefG15ma",
        "clefG15mb",
        "clefF",
        "clefF8va",
        "clefF8vb",
        "clefF15ma",
        "clefF15mb",
        "clefC",
        "clefPercussion",
        "accidentalSharp",
        "accidentalFlat",
        "accidentalNatural",
        "accidentalDoubleSharp",
        "accidentalDoubleFlat",
        "timeSig0",
        "timeSig1",
        "timeSig2",
        "timeSig3",
        "timeSig4",
        "timeSig5",
        "timeSig6",
        "timeSig7",
        "timeSig8",
        "timeSig9",
        "timeSigCommon",
        "timeSigCutTime",
        "repeatBarlineDots",
        "segno",
        "coda",
        "dalSegno",
        "daCapo",
        "fermata",
        "dynamic",
        "articulation",
        "ornament",
    ]

    /// `"restOther"` deliberately returns `nil` — it has no unique inverse,
    /// see the type doc comment.
    static func semantic(forClassName name: String) -> SMuFLSemantic? {
        if let s = semanticByName[name] { return s }
        switch name {
        case "stem": return .stem
        case "staff5Lines": return .staff5Lines
        case "rest128th": return .rest(.oneTwentyEighth)
        case "rest256th": return .rest(.twoFiftySixth)
        default: break
        }
        if name.hasPrefix("unknown"), name.count > "unknown".count,
           let cp = UInt32(name.dropFirst("unknown".count), radix: 16)
        {
            return .unknown(cp)
        }
        return nil
    }
}
