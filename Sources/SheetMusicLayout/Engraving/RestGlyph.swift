import SheetMusicCore
import SheetMusicFoundation

/// Pick the SMuFL rest glyph for the given duration.
///
/// `.measure` is the marker for "this rest fills the containing
/// measure" and engraves as a whole-rest. When the rest is hung above
/// or below the staff (`hasLegerLine == true`), MuseScore swaps to the
/// leger-bearing variants so the rest comes with its own short ledger
/// stroke — see `Rest::getSymbol`.
public enum RestGlyph {
    public static func codepoint(
        duration: NoteDuration, hasLegerLine: Bool = false,
    ) -> UInt32 {
        switch duration {
        case .whole, .measure:
            hasLegerLine
                ? SMuFLCodepoint.restWholeLegerLine
                : SMuFLCodepoint.restWhole
        case .half:
            hasLegerLine
                ? SMuFLCodepoint.restHalfLegerLine
                : SMuFLCodepoint.restHalf
        case .quarter: SMuFLCodepoint.restQuarter
        case .eighth: SMuFLCodepoint.rest8th
        case .sixteenth: SMuFLCodepoint.rest16th
        case .thirtySecond: SMuFLCodepoint.rest32nd
        case .sixtyFourth: SMuFLCodepoint.rest64th
        // Sub-64th and fraction durations are rare in practice; render
        // them as 64th rests until callers need finer control.
        case .oneTwentyEighth, .twoFiftySixth, .fraction:
            SMuFLCodepoint.rest64th
        }
    }
}
