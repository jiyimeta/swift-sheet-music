import Foundation
import SheetMusicCore

/// TIER 1b — noteheads a font draws from SMuFL's font-specific
/// **optional-glyph range**, U+F400–U+F8FF.
///
/// WHY THIS EXISTS. MuseScore engraves noteheads for **Bravura and
/// Petaluma** at U+F4BA / U+F4BC / U+F4BD / U+F4BE rather than the
/// standard U+E0A0 / U+E0A2 / U+E0A3 / U+E0A4, while leaving every other
/// glyph class — clefs, rests, flags, accidentals, time signatures — on
/// the standard codepoints. Tier 1 knows only the standard column, so
/// before this tier such a PDF imported with **zero notes** (measured on
/// one generated fixture: `notesA=84 notesB=0`, while the Leland export
/// of the same score recovered all 84). Bravura is the SMuFL reference
/// font, so that is a first-order import failure.
///
/// WHAT THE GLYPHS ARE. Not cmap aliases: in the bundled `Bravura.otf`,
/// U+E0A4 is gid 158 and U+F4BE is gid 2992, two separate outlines of
/// the same shape about 12% apart (E0A4 bbox 295×250 advance 295;
/// F4BE bbox 329×280 advance 329; six CGPath elements each). The CFF
/// charset names them only `uniXXXX`, so the font supplies no semantic
/// name and the shape correspondence is the only evidence of meaning.
///
/// WHY THE TABLE IS SEPARATE FROM `smuflSemantic`. SMuFL defines
/// U+F400–U+F8FF as **font-specific**. A codepoint in that range means
/// whatever the font says it means, so an unconditional global claim
/// would be unsound by spec — and the failure it invites is the worst
/// kind this importer has: a font squatting on U+F4BE would have notes
/// *invented* for it rather than merely omitted (`GlyphClassifier+MusicFontGate.swift`
/// records that "icon fonts are known to squat on Private Use Area
/// codepoints too"). So this table is consulted only for a font that has
/// shown, in its own `/ToUnicode` CMap, that it speaks standard SMuFL —
/// see `ToUnicodeCMap.mapsRecognizedStandardSMuFLCodepoints`.
///
/// A font-NAME allowlist is not used, deliberately: that is the approach
/// the music-font gate rejected, because a subsetted PDF font's
/// `/BaseFont` is "frequently mangled by the subsetting prefix or missing
/// entirely".
///
/// SCOPE OF THE CLAIM, measured rather than assumed:
/// - Across the 132 PDFs of the real corpus the only optional-range
///   scalar that occurs at all is U+F400, six times — not one of these
///   four. Existing imports are therefore untouched by construction.
/// - Six user-authored scores re-engraved in Petaluma all carry
///   U+F4BC/F4BD/F4BE, and **five of the six were exported by MuseScore
///   3**. This is font-specific behavior, not a MuseScore-4 quirk.
///
/// This file is Foundation-only on purpose. The classifier cascade is
/// CoreText-based and excluded from the Android build; keeping the table
/// and its gate here is what lets the Android reader — where PDF import
/// is a shipped, device-verified feature — get the same fix.
extension PDFImporter {
    /// SMuFL's font-specific optional-glyph range. Everything below
    /// U+F400 is the standard range, whose meanings are fixed by the
    /// specification and belong to `smuflSemantic`.
    static let smuflOptionalGlyphRange: ClosedRange<UInt32> = 0xF400 ... 0xF8FF

    /// Optional-range codepoint → the STANDARD-range codepoint whose glyph
    /// it duplicates at a larger size.
    ///
    /// Deliberately maps to a CODEPOINT rather than to a semantic, so the
    /// semantic is read back out of `smuflSemantic` and the two tables
    /// cannot drift apart — `everyAliasPointsAtACodepointTier1Recognizes`
    /// asserts exactly that.
    ///
    /// Note U+F4BB is absent. The block is contiguous in the font
    /// (gids 2988…2992 mirroring 154…158), but U+E0A1
    /// `noteheadDoubleWholeSquare` is the only member whose standard
    /// partner this importer treats as a variant spelling rather than a
    /// distinct head, and no measured PDF has ever drawn it. Claiming it
    /// unmeasured would widen the table for nothing.
    static let smuflOptionalNoteheadAliases: [UInt32: UInt32] = [
        0xF4BA: 0xE0A0, // noteheadDoubleWhole
        0xF4BC: 0xE0A2, // noteheadWhole
        0xF4BD: 0xE0A3, // noteheadHalf
        0xF4BE: 0xE0A4, // noteheadBlack
    ]

    /// The semantic for an optional-range codepoint this table knows, or
    /// `nil` for every other codepoint — including standard-range ones,
    /// which are Tier 1's business, and optional-range ones the table does
    /// not claim, which must keep falling through to `.unknown`.
    ///
    /// CALLERS MUST GATE THIS on the font's own evidence
    /// (`ToUnicodeCMap.mapsRecognizedStandardSMuFLCodepoints`); the
    /// function itself has no way to know which font asked.
    static func smuflOptionalRangeSemantic(codepoint: UInt32) -> SMuFLSemantic? {
        guard let standard = smuflOptionalNoteheadAliases[codepoint] else { return nil }
        let semantic = smuflSemantic(codepoint: standard)
        if case .unknown = semantic { return nil }
        return semantic
    }
}
