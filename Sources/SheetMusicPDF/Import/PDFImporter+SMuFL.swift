import Foundation
import SheetMusicCore

extension PDFImporter {
    /// Map a SMuFL codepoint to its semantic. Unrecognized codepoints
    /// → `.unknown(codepoint)` so callers can emit a diagnostic.
    static func smuflSemantic(codepoint cp: UInt32) -> SMuFLSemantic {
        switch cp {
        case 0xE000: return .brace
        case 0xE003: return .staff5Lines
        // Both spellings of a repeat barline's dots. U+E043 `repeatDots`
        // is the pair as one glyph; U+E044 `repeatDot` is a single dot,
        // and MuseScore draws the pair as TWO of those at the same x
        // (upstream rendering/score/tdraw.cpp:683-684) — so no
        // MuseScore-engraved repeat barline contains U+E043 at all, and
        // mapping only it recognized none of them. They collapse to one
        // semantic because nothing downstream counts the dots
        // (PDFImporter+Structure's repeatDotsCount is read through > 0).
        case 0xE043, 0xE044: return .repeatBarlineDots
        // The two jump words SMuFL draws as glyphs. There is no `fine`
        // and no `toCoda` glyph in the specification — only `coda`
        // U+E048 and `codaSquare` U+E049 — so those two markers are
        // recovered from the text stream instead (PDFImporter+Structure).
        case 0xE045: return .dalSegno
        case 0xE046: return .daCapo
        case 0xE047: return .segno
        case 0xE048: return .coda
        case 0xE050: return .clefG
        case 0xE051: return .clefG15mb // gClef15mb — treble two octaves down
        case 0xE052: return .clefG8vb // gClef8vb — vocal tenor clef
        case 0xE053: return .clefG8va // gClef8va — treble one octave up
        case 0xE054: return .clefG15ma // gClef15ma — treble two octaves up
        case 0xE05C: return .clefC
        case 0xE062: return .clefF
        case 0xE063: return .clefF15mb // fClef15mb — bass two octaves down
        case 0xE064: return .clefF8vb // fClef8vb — bass one octave down
        case 0xE065: return .clefF8va // fClef8va — bass one octave up
        case 0xE066: return .clefF15ma // fClef15ma — bass two octaves up
        case 0xE069: return .clefPercussion
        case 0xE08A: return .timeSignatureCommon
        case 0xE08B: return .timeSignatureCutTime
        // U+E0A0 is the plain double whole; U+E0A1 is
        // `noteheadDoubleWholeSquare`. Only E0A1 used to be listed, so every
        // breve was silently dropped from every import, in every font — this
        // package's own SMuFLCodepoints+Noteheads.swift:159-160 has the pair
        // right. Both map to the same semantic on purpose: they are the same
        // duration and this importer's Note model carries no head shape,
        // which is the same treatment the shape-note cases below get.
        case 0xE0A0: return .noteheadDoubleWhole
        case 0xE0A1: return .noteheadDoubleWhole // noteheadDoubleWholeSquare
        case 0xE0A2: return .noteheadWhole
        case 0xE0A3: return .noteheadHalf
        case 0xE0A4: return .noteheadBlack
        // X-noteheads (drum-staff cymbals / hi-hat). They flow through the
        // notehead path like normal noteheads (isNotehead / cluster / pitch).
        case 0xE0A7: return .noteheadXWhole
        case 0xE0A8: return .noteheadXHalf
        case 0xE0A9: return .noteheadXBlack
        // Shape-note / alternate notehead GROUPS an arranger can assign per
        // note (MuseScore `<head>` overrides). The importer's Note model does
        // not carry head shape, so each maps to the behaviourally-equivalent
        // standard notehead — same pitch (staff position) and the same base
        // duration, so beams / flags resolve length identically. Without this
        // they fall to `.unknown` and the note is silently dropped (observed
        // on ロビンソン's beatbox parts: 34 `mi` + `withx` notes lost, e.g. the
        // 2nd of every beamed pair). `mi` (diamond) prints filled at quarter
        // base; `withx` prints as a void-with-X glyph even for the 16th / 8th
        // notes that carry it, so it needs a quarter (beamable) base too — a
        // half base would freeze it at a half note.
        case 0xE1B9: return .noteheadBlack // noteShapeDiamondBlack ("mi" head)
        case 0xE0B7: return .noteheadXBlack // noteheadVoidWithX ("withx" head)
        case 0xE1E7: return .augmentationDot
        case 0xE240: return .flag8thUp
        case 0xE241: return .flag8thDown
        case 0xE242: return .flag16thUp
        case 0xE243: return .flag16thDown
        case 0xE244: return .flag32ndUp
        case 0xE245: return .flag32ndDown
        case 0xE246: return .flag64thUp
        case 0xE247: return .flag64thDown
        case 0xE260: return .accidentalFlat
        case 0xE261: return .accidentalNatural
        case 0xE262: return .accidentalSharp
        case 0xE263: return .accidentalDoubleSharp
        case 0xE264: return .accidentalDoubleFlat
        // Rests — only the durations supported by NoteDuration:
        case 0xE4E3: return .rest(.whole)
        case 0xE4E4: return .rest(.half)
        case 0xE4E5: return .rest(.quarter)
        case 0xE4E6: return .rest(.eighth)
        case 0xE4E7: return .rest(.sixteenth)
        case 0xE4E8: return .rest(.thirtySecond)
        case 0xE4E9: return .rest(.sixtyFourth)
        default:
            return rangeSemantic(codepoint: cp)
        }
    }

    /// The cases SMuFL defines as RANGES rather than as single glyphs.
    ///
    /// Split out of `smuflSemantic` only because that switch outgrew the
    /// function-length limit; the two are one table read in order, and a
    /// codepoint reaching here has already missed every point case above
    /// — so no range can shadow a more specific mapping, whatever order
    /// the cases are written in.
    ///
    /// A blanket range claim is safe in the STANDARD range and would not
    /// be in U+F400–F8FF, where a codepoint means whatever the font says
    /// it means. That is why the optional-range notehead aliases live in
    /// their own evidence-gated table (`PDFImporter+SMuFLOptionalRange`)
    /// instead of in here.
    private static func rangeSemantic(codepoint cp: UInt32) -> SMuFLSemantic {
        switch cp {
        case 0xE080 ... 0xE089: return .timeSignatureDigit(Int(cp - 0xE080))
        // The whole fermata family, not just `fermataAbove`. SMuFL's
        // "Holds and pauses" range is U+E4C0–U+E4DF, but only its
        // contiguous prefix U+E4C0–U+E4CD is fermatas (…Above/…Below in
        // pairs, through the Henze variants); U+E4CE onward is breath
        // marks and caesuras, which are not fermatas and have no
        // semantic here. Endpoints read out of SMuFL's own
        // `glyphnames.json` / `ranges.json`, not inferred. Mapping only
        // U+E4C0 left `fermataBelow` — engraved under any bottom staff —
        // falling through to `.unknown`.
        case 0xE4C0 ... 0xE4CD: return .fermata
        // Coarse buckets. The importer models none of these three, and
        // classifying them is precisely so their ink is ACCOUNTED FOR
        // rather than left to be mistaken for a neighbouring class —
        // nothing downstream switches on them, exactly as with `.segno`
        // and `.coda`. The ornament bucket is two adjacent SMuFL ranges
        // (commonOrnaments U+E560–E56F, otherBaroqueOrnaments
        // U+E570–E58F) that happen to abut.
        case 0xE4A0 ... 0xE4BF, // articulation
             0xED40 ... 0xED4F: // articulationSupplement
            return .articulation
        case 0xE520 ... 0xE54F: return .dynamic
        case 0xE560 ... 0xE58F: return .ornament
        default:
            return .unknown(cp)
        }
    }
}
