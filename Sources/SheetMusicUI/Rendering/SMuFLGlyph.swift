import CoreGraphics
import SheetMusicLayout

/// `Character`-typed wrapper around `SheetMusicLayout.SMuFLCodepoint`.
///
/// SwiftUI's `GraphicsContext.drawGlyph` takes a `Character`, so the
/// Apple renderers need the codepoints in that form. The numeric values
/// live in `SheetMusicLayout` (cross-platform); this file is a thin
/// platform shim, not a second source of truth.
enum SMuFLGlyph {
    // MARK: - Clefs

    static let gClef: Character = scalar(SMuFLCodepoint.gClef)
    static let gClef15mb: Character = scalar(SMuFLCodepoint.gClef15mb)
    static let gClef8vb: Character = scalar(SMuFLCodepoint.gClef8vb)
    static let gClef8va: Character = scalar(SMuFLCodepoint.gClef8va)
    static let gClef15ma: Character = scalar(SMuFLCodepoint.gClef15ma)
    static let fClef: Character = scalar(SMuFLCodepoint.fClef)
    static let fClef15mb: Character = scalar(SMuFLCodepoint.fClef15mb)
    static let fClef8vb: Character = scalar(SMuFLCodepoint.fClef8vb)
    static let fClef8va: Character = scalar(SMuFLCodepoint.fClef8va)
    static let cClef: Character = scalar(SMuFLCodepoint.cClef)
    static let percussionClef: Character = scalar(SMuFLCodepoint.percussionClef)
    static let percussionClef2: Character = scalar(SMuFLCodepoint.percussionClef2)

    // MARK: - Noteheads — standard

    static let noteheadWhole: Character = scalar(SMuFLCodepoint.noteheadWhole)
    static let noteheadHalf: Character = scalar(SMuFLCodepoint.noteheadHalf)
    static let noteheadBlack: Character = scalar(SMuFLCodepoint.noteheadBlack)

    // MARK: - Noteheads — cross (x)

    static let noteheadXDoubleWhole: Character = scalar(SMuFLCodepoint.noteheadXDoubleWhole)
    static let noteheadXWhole: Character = scalar(SMuFLCodepoint.noteheadXWhole)
    static let noteheadXHalf: Character = scalar(SMuFLCodepoint.noteheadXHalf)
    static let noteheadXBlack: Character = scalar(SMuFLCodepoint.noteheadXBlack)

    // MARK: - Noteheads — diamond

    static let noteheadDiamondWhole: Character = scalar(SMuFLCodepoint.noteheadDiamondWhole)
    static let noteheadDiamondHalf: Character = scalar(SMuFLCodepoint.noteheadDiamondHalf)
    static let noteheadDiamondBlack: Character = scalar(SMuFLCodepoint.noteheadDiamondBlack)

    // MARK: - Noteheads — triangle

    static let noteheadTriangleUpBlack: Character = scalar(SMuFLCodepoint.noteheadTriangleUpBlack)
    static let noteheadTriangleDownBlack: Character = scalar(SMuFLCodepoint.noteheadTriangleDownBlack)

    // MARK: - Flags

    static let flag8thUp: Character = scalar(SMuFLCodepoint.flag8thUp)
    static let flag8thDown: Character = scalar(SMuFLCodepoint.flag8thDown)
    static let flag16thUp: Character = scalar(SMuFLCodepoint.flag16thUp)
    static let flag16thDown: Character = scalar(SMuFLCodepoint.flag16thDown)
    static let flag32ndUp: Character = scalar(SMuFLCodepoint.flag32ndUp)
    static let flag32ndDown: Character = scalar(SMuFLCodepoint.flag32ndDown)
    static let flag64thUp: Character = scalar(SMuFLCodepoint.flag64thUp)
    static let flag64thDown: Character = scalar(SMuFLCodepoint.flag64thDown)

    // MARK: - Rests

    static let restWhole: Character = scalar(SMuFLCodepoint.restWhole)
    static let restHalf: Character = scalar(SMuFLCodepoint.restHalf)
    static let restWholeLegerLine: Character = scalar(SMuFLCodepoint.restWholeLegerLine)
    static let restHalfLegerLine: Character = scalar(SMuFLCodepoint.restHalfLegerLine)
    static let restHBar: Character = scalar(SMuFLCodepoint.restHBar)
    static let restHBarLeft: Character = scalar(SMuFLCodepoint.restHBarLeft)
    static let restHBarRight: Character = scalar(SMuFLCodepoint.restHBarRight)
    static let restQuarter: Character = scalar(SMuFLCodepoint.restQuarter)
    static let rest8th: Character = scalar(SMuFLCodepoint.rest8th)
    static let rest16th: Character = scalar(SMuFLCodepoint.rest16th)
    static let rest32nd: Character = scalar(SMuFLCodepoint.rest32nd)
    static let rest64th: Character = scalar(SMuFLCodepoint.rest64th)

    // MARK: - Accidentals

    static let accidentalSharp: Character = scalar(SMuFLCodepoint.accidentalSharp)
    static let accidentalFlat: Character = scalar(SMuFLCodepoint.accidentalFlat)
    static let accidentalNatural: Character = scalar(SMuFLCodepoint.accidentalNatural)
    static let accidentalDoubleSharp: Character = scalar(SMuFLCodepoint.accidentalDoubleSharp)
    static let accidentalDoubleFlat: Character = scalar(SMuFLCodepoint.accidentalDoubleFlat)

    // MARK: - Time signatures

    static func timeSigDigit(_ d: Int) -> Character {
        scalar(SMuFLCodepoint.timeSigDigit(d))
    }

    static let timeSigCommon: Character = scalar(SMuFLCodepoint.timeSigCommon)
    static let timeSigCutCommon: Character = scalar(SMuFLCodepoint.timeSigCutCommon)

    // MARK: - Navigation marks

    static let segno: Character = scalar(SMuFLCodepoint.segno)
    static let coda: Character = scalar(SMuFLCodepoint.coda)
    static let fermataAbove: Character = scalar(SMuFLCodepoint.fermataAbove)
    static let fermataBelow: Character = scalar(SMuFLCodepoint.fermataBelow)

    // MARK: - Articulations

    static let articStaccatoAbove: Character = scalar(SMuFLCodepoint.articStaccatoAbove)
    static let articStaccatoBelow: Character = scalar(SMuFLCodepoint.articStaccatoBelow)
    static let articTenutoAbove: Character = scalar(SMuFLCodepoint.articTenutoAbove)
    static let articTenutoBelow: Character = scalar(SMuFLCodepoint.articTenutoBelow)
    static let articStaccatissimoAbove: Character = scalar(SMuFLCodepoint.articStaccatissimoAbove)
    static let articStaccatissimoBelow: Character = scalar(SMuFLCodepoint.articStaccatissimoBelow)
    static let articAccentAbove: Character = scalar(SMuFLCodepoint.articAccentAbove)
    static let articAccentBelow: Character = scalar(SMuFLCodepoint.articAccentBelow)
    static let articMarcatoAbove: Character = scalar(SMuFLCodepoint.articMarcatoAbove)
    static let articMarcatoBelow: Character = scalar(SMuFLCodepoint.articMarcatoBelow)
    static let articAccentStaccatoAbove: Character = scalar(SMuFLCodepoint.articAccentStaccatoAbove)
    static let articAccentStaccatoBelow: Character = scalar(SMuFLCodepoint.articAccentStaccatoBelow)
    static let articMarcatoStaccatoAbove: Character = scalar(SMuFLCodepoint.articMarcatoStaccatoAbove)
    static let articMarcatoStaccatoBelow: Character = scalar(SMuFLCodepoint.articMarcatoStaccatoBelow)

    // MARK: - Brackets + braces

    static let brace: Character = scalar(SMuFLCodepoint.brace)
    static let braceSmall: Character = scalar(SMuFLCodepoint.braceSmall)
    static let braceLarge: Character = scalar(SMuFLCodepoint.braceLarge)
    static let braceLarger: Character = scalar(SMuFLCodepoint.braceLarger)
    static let bracketTop: Character = scalar(SMuFLCodepoint.bracketTop)
    static let bracketBottom: Character = scalar(SMuFLCodepoint.bracketBottom)

    /// Pick the brace SMuFL codepoint and the X-magnification factor
    /// for a given staff span, matching MuseScore's
    /// `Bracket::computeMagx`. Returns `(codepoint, magx)`. Delegates to
    /// the cross-platform `BraceMetrics.variant` so the Apple renderer and
    /// the Android draw-command bridge share one source of truth.
    static func braceVariant(staffCount: Int) -> (UInt16, CGFloat) {
        BraceMetrics.variant(staffCount: staffCount)
    }

    // MARK: - Keyboard pedal

    static let keyboardPedalPed: Character = scalar(SMuFLCodepoint.keyboardPedalPed)
    static let keyboardPedalUp: Character = scalar(SMuFLCodepoint.keyboardPedalUp)

    // MARK: - Dynamics

    static let dynamicPiano: Character = scalar(SMuFLCodepoint.dynamicPiano)
    static let dynamicMezzo: Character = scalar(SMuFLCodepoint.dynamicMezzo)
    static let dynamicForte: Character = scalar(SMuFLCodepoint.dynamicForte)
    static let dynamicRinforzando: Character = scalar(SMuFLCodepoint.dynamicRinforzando)
    static let dynamicSforzando: Character = scalar(SMuFLCodepoint.dynamicSforzando)
    static let dynamicZ: Character = scalar(SMuFLCodepoint.dynamicZ)
    static let dynamicNiente: Character = scalar(SMuFLCodepoint.dynamicNiente)

    // MARK: - Arpeggio / measure repeat

    static let arpeggioWiggle: Character = scalar(SMuFLCodepoint.arpeggioWiggle)
    static let arpeggioUpArrow: Character = scalar(SMuFLCodepoint.arpeggioUpArrow)
    static let arpeggioDownArrow: Character = scalar(SMuFLCodepoint.arpeggioDownArrow)
    static let repeat1Bar: Character = scalar(SMuFLCodepoint.repeat1Bar)
    static let repeat2Bars: Character = scalar(SMuFLCodepoint.repeat2Bars)
    static let repeat4Bars: Character = scalar(SMuFLCodepoint.repeat4Bars)

    /// SMuFL codepoints are guaranteed valid Unicode scalars (PUA).
    private static func scalar(_ cp: UInt32) -> Character {
        // swiftlint:disable:next force_unwrapping
        Character(UnicodeScalar(cp)!)
    }
}
