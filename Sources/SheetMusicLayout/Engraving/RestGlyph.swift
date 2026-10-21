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
        case .long: SMuFLCodepoint.restLonga
        case .breve:
            hasLegerLine
                ? SMuFLCodepoint.restDoubleWholeLegerLine
                : SMuFLCodepoint.restDoubleWhole
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
        case .oneTwentyEighth, .twoFiftySixth, .fiveHundredTwelfth, .oneThousandTwentyFourth, .fraction:
            SMuFLCodepoint.rest64th
        }
    }
}

extension RestGlyph {
    /// `codepoint(duration:hasLegerLine:)` for a rest drawn in a measure whose `LayoutMeasure.measureRestsAreBreves`
    /// is `measureRestsAreBreves`: a full-measure rest there takes the breve rest.
    public static func codepoint(
        duration: NoteDuration, hasLegerLine: Bool, measureRestsAreBreves: Bool,
    ) -> UInt32 {
        codepoint(
            duration: duration == .measure && measureRestsAreBreves ? .breve : duration,
            hasLegerLine: hasLegerLine,
        )
    }
}

extension LayoutEngine {
    /// The rest a full-measure rest draws as in a bar of `measureDuration`: the breve rest once the bar holds two
    /// whole notes or more, as MuseScore draws it (`Rest::isBreveRest`), and the whole rest below that.
    static func measureRestBase(in measureDuration: Fraction) -> NoteDuration {
        measureDuration.numerator >= 2 * measureDuration.denominator ? .breve : .whole
    }
}
