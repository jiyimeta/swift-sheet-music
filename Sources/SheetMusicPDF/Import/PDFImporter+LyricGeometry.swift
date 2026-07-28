#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

// Geometry helpers for lyric-to-note attachment. Split out of
// PDFImporter+Lyrics to stay under the 400-line file cap.
//
// The one idea here: MuseScore CENTRES a syllable under its notehead, so
// every comparison between a syllable and the note grid must put BOTH
// sides on their centres. Mixing landmarks — a syllable centre against a
// notehead left edge, or vice versa — silently re-introduces a half-glyph
// bias, which is what made this pass depend on a walker bug for years.

extension PDFImporter {
    /// Width of a notehead in spatia. SMuFL `noteheadBlack` is ~1.18 sp —
    /// the same figure `PDFImporter+TupletApply` records. Used only to turn
    /// the stored notehead ORIGIN into a notehead CENTRE.
    static let noteheadWidthSpatia: CGFloat = 1.18

    /// Advance of one East-Asian full-width character, in ems. Kana, kanji
    /// and the fullwidth forms occupy a full em box by definition — this is
    /// a typographic invariant of the script, not a tuned value.
    static let fullWidthAdvanceEm: CGFloat = 1.0

    /// Mean advance of a Latin lyric character, in ems. Proportional faces
    /// vary per letter ("i" ≈ 0.28, "m" ≈ 0.78); half an em is the usual
    /// average and is the same figure the content-stream walker already
    /// uses for its own approximate advance (`fontSize * 0.5`).
    static let latinAdvanceEm: CGFloat = 0.5

    /// Horizontal CENTRE of a lyric glyph's ink, in page space.
    ///
    /// MuseScore CENTRES a syllable under its note, so the centre — not the
    /// left edge — is what the nearest-note snap must compare against the
    /// note grid. `origin.x` is the left edge (see `PendingTextRun`), so the
    /// centre lies half an advance to its right.
    ///
    /// WHY THIS IS NEEDED. Until the walker was fixed, a run's origin was
    /// recorded one approximate advance (`renderedSize * 0.5`) to the RIGHT
    /// of its ink. For a full-width kana that lands exactly on the glyph's
    /// centre, so the old snap was accidentally centre-based and this whole
    /// pass was calibrated against it. Correcting the origin to the true
    /// left edge therefore biased every syllable toward the PREVIOUS note:
    /// measured on 旅路, 60 of 2348 glyph snaps moved one note left and none
    /// moved right; on 革命道中, 48 of 2164. Comparing centres restores the
    /// intended behavior on CJK while also fixing Latin, where the old
    /// blanket half-em OVERSHOT a narrow letter's true centre.
    ///
    /// `TextGlyph` carries no per-glyph width, so the advance is estimated
    /// by character class. A run may hold several characters (the CMap loop
    /// accumulates consecutive non-PUA codes), so they are summed.
    static func centerX(_ glyph: TextGlyph) -> CGFloat {
        let trimmed = glyph.text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, glyph.renderedSize > 0 else { return glyph.origin.x }
        var ems: CGFloat = 0
        for scalar in trimmed.unicodeScalars {
            ems += isFullWidth(scalar) ? fullWidthAdvanceEm : latinAdvanceEm
        }
        return glyph.origin.x + glyph.renderedSize * ems / 2
    }

    /// Whether `scalar` occupies a full em box (Unicode East Asian Width
    /// W / F). Covers the kana, kanji and fullwidth forms Japanese lyrics
    /// are written in; anything else is treated as proportional Latin.
    private static func isFullWidth(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100 ... 0x115F, // Hangul Jamo
             0x2E80 ... 0x303E, // CJK radicals, Kangxi, CJK symbols
             0x3041 ... 0x33FF, // kana, Bopomofo, compat Jamo, enclosed CJK
             0x3400 ... 0x4DBF, // CJK unified ext A
             0x4E00 ... 0x9FFF, // CJK unified
             0xA000 ... 0xA4CF, // Yi
             0xAC00 ... 0xD7A3, // Hangul syllables
             0xF900 ... 0xFAFF, // CJK compatibility ideographs
             0xFE30 ... 0xFE4F, // CJK compatibility forms
             0xFF00 ... 0xFF60, // fullwidth forms
             0xFFE0 ... 0xFFE6: // fullwidth signs
            true
        default:
            false
        }
    }

    /// Index (into the x-sorted note list) of the note nearest `x`.
    static func nearestNotePos(_ x: CGFloat, _ noteXs: [CGFloat]) -> Int {
        var best = 0
        var bestDist = CGFloat.infinity
        for (i, nx) in noteXs.enumerated() {
            let d = abs(nx - x)
            if d < bestDist {
                bestDist = d
                best = i
            }
        }
        return best
    }
}
