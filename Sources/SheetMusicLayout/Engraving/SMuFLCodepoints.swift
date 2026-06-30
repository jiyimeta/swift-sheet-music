#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Bravura / SMuFL Private Use Area codepoints used by the engraving
/// layer.
///
/// Values come from the SMuFL standard (https://www.smufl.org/) and
/// `glyphnames.json`. These constants are the single source of truth
/// for SMuFL codepoints across the package; Apple renderers wrap them
/// as `Character` (`SheetMusicUI.SMuFLGlyph`) for `GraphicsContext`
/// drawing, while the Android `LayoutBridge` emits the raw `UInt32`
/// codepoints into the wire format.
public enum SMuFLCodepoint {
    // MARK: - Clefs

    public static let gClef: UInt32 = 0xE050
    public static let gClef15mb: UInt32 = 0xE051
    public static let gClef8vb: UInt32 = 0xE052
    public static let gClef8va: UInt32 = 0xE053
    public static let gClef15ma: UInt32 = 0xE054
    public static let cClef: UInt32 = 0xE05C
    public static let fClef: UInt32 = 0xE062
    public static let fClef15mb: UInt32 = 0xE063
    public static let fClef8vb: UInt32 = 0xE064
    public static let fClef8va: UInt32 = 0xE065
    public static let fClef15ma: UInt32 = 0xE066
    public static let percussionClef: UInt32 = 0xE069
    public static let percussionClef2: UInt32 = 0xE06A

    // MARK: - Flags

    public static let flag8thUp: UInt32 = 0xE240
    public static let flag8thDown: UInt32 = 0xE241
    public static let flag16thUp: UInt32 = 0xE242
    public static let flag16thDown: UInt32 = 0xE243
    public static let flag32ndUp: UInt32 = 0xE244
    public static let flag32ndDown: UInt32 = 0xE245
    public static let flag64thUp: UInt32 = 0xE246
    public static let flag64thDown: UInt32 = 0xE247

    // MARK: - Rests

    public static let restWhole: UInt32 = 0xE4E3
    public static let restHalf: UInt32 = 0xE4E4
    /// Whole-rest variant with a baked-in leger line — used when the
    /// rest is hung above or below the staff. MuseScore swaps to this
    /// via `Rest::getSymbol` when `line` is outside the staff range.
    public static let restWholeLegerLine: UInt32 = 0xE4F4
    /// Half-rest variant with a baked-in leger line.
    public static let restHalfLegerLine: UInt32 = 0xE4F5
    /// Multi-measure rest H-bar (thick horizontal beam used in part
    /// scores to compress long stretches of silence).
    public static let restHBar: UInt32 = 0xE4EE
    /// Left-side cap glyph for `restHBar`.
    public static let restHBarLeft: UInt32 = 0xE4EF
    /// Right-side cap glyph for `restHBar`.
    public static let restHBarRight: UInt32 = 0xE4F0
    public static let restQuarter: UInt32 = 0xE4E5
    public static let rest8th: UInt32 = 0xE4E6
    public static let rest16th: UInt32 = 0xE4E7
    public static let rest32nd: UInt32 = 0xE4E8
    public static let rest64th: UInt32 = 0xE4E9

    // MARK: - Time signatures

    /// Base codepoint for the digit "0". `timeSigDigit(_:)` adds an
    /// integer in `0...9`.
    public static let timeSig0: UInt32 = 0xE080
    public static let timeSigCommon: UInt32 = 0xE08A
    public static let timeSigCutCommon: UInt32 = 0xE08B

    /// Convenience for the `0…9` time-signature digit range.
    public static func timeSigDigit(_ d: Int) -> UInt32 {
        timeSig0 + UInt32(max(0, min(9, d)))
    }

    // MARK: - Navigation marks

    public static let segno: UInt32 = 0xE047
    public static let coda: UInt32 = 0xE048
    public static let fermataAbove: UInt32 = 0xE4C0
    public static let fermataBelow: UInt32 = 0xE4C1

    // MARK: - Breath marks + caesuras

    /// Breath mark (comma) — SMuFL `breathMarkComma`.
    public static let breathMarkComma: UInt32 = 0xE4CE
    /// Breath mark (tick) — SMuFL `breathMarkTick`.
    public static let breathMarkTick: UInt32 = 0xE4CF
    /// Breath mark (up bow) — SMuFL `breathMarkUpbow`.
    public static let breathMarkUpbow: UInt32 = 0xE4D0
    /// Breath mark (Salzedo) — SMuFL `breathMarkSalzedo`.
    public static let breathMarkSalzedo: UInt32 = 0xE4D5
    /// Caesura — SMuFL `caesura`.
    public static let caesura: UInt32 = 0xE4D1
    /// Short caesura — SMuFL `caesuraShort`.
    public static let caesuraShort: UInt32 = 0xE4D3
    /// Thick caesura — SMuFL `caesuraThick`.
    public static let caesuraThick: UInt32 = 0xE4D2
    /// Curved caesura — SMuFL `caesuraCurved`.
    public static let caesuraCurved: UInt32 = 0xE4D4

    // MARK: - Articulations

    /// Above/below pairs render the same shape mirrored across the
    /// baseline; MuseScore picks the variant from the articulation's
    /// resolved anchor side.
    public static let articStaccatoAbove: UInt32 = 0xE4A2
    public static let articStaccatoBelow: UInt32 = 0xE4A3
    public static let articTenutoAbove: UInt32 = 0xE4A4
    public static let articTenutoBelow: UInt32 = 0xE4A5
    public static let articStaccatissimoAbove: UInt32 = 0xE4A6
    public static let articStaccatissimoBelow: UInt32 = 0xE4A7
    public static let articAccentAbove: UInt32 = 0xE4A0
    public static let articAccentBelow: UInt32 = 0xE4A1
    public static let articMarcatoAbove: UInt32 = 0xE4AC
    public static let articMarcatoBelow: UInt32 = 0xE4AD
    public static let articAccentStaccatoAbove: UInt32 = 0xE4B0
    public static let articAccentStaccatoBelow: UInt32 = 0xE4B1
    public static let articMarcatoStaccatoAbove: UInt32 = 0xE4AE
    public static let articMarcatoStaccatoBelow: UInt32 = 0xE4AF

    // MARK: - Brackets + braces

    /// MuseScore picks one of four brace variants per number of spanned
    /// staves (`engraving/dom/bracket.cpp::Bracket::computeMagx`):
    /// v=1 → braceSmall, v=2 → brace, v=3 → braceLarge, v≥4 → braceLarger.
    public static let brace: UInt32 = 0xE000
    public static let braceSmall: UInt32 = 0xF400
    public static let braceLarge: UInt32 = 0xF401
    public static let braceLarger: UInt32 = 0xF402
    public static let bracketTop: UInt32 = 0xE003
    public static let bracketBottom: UInt32 = 0xE004

    // MARK: - Keyboard pedal

    /// MuseScore renders pedal lines using these glyphs from the music
    /// font, not text. The bold serif weight makes them visually
    /// distinct from prose text.
    public static let keyboardPedalPed: UInt32 = 0xE650
    public static let keyboardPedalUp: UInt32 = 0xE655

    // MARK: - Dynamics

    /// MuseScore composes multi-letter dynamics (mp, mf, ff, fff, …)
    /// from these atomic letters per `dynamic.cpp` DYN_LIST.
    public static let dynamicPiano: UInt32 = 0xE520
    public static let dynamicMezzo: UInt32 = 0xE521
    public static let dynamicForte: UInt32 = 0xE522
    public static let dynamicRinforzando: UInt32 = 0xE523
    public static let dynamicSforzando: UInt32 = 0xE524
    public static let dynamicZ: UInt32 = 0xE525
    public static let dynamicNiente: UInt32 = 0xE526

    // MARK: - Arpeggio / measure repeat

    public static let arpeggioWiggle: UInt32 = 0xEAA9
    public static let arpeggioUpArrow: UInt32 = 0xEAAD
    public static let arpeggioDownArrow: UInt32 = 0xEAAE
    public static let repeat1Bar: UInt32 = 0xE500
    public static let repeat2Bars: UInt32 = 0xE501
    public static let repeat4Bars: UInt32 = 0xE502
}
