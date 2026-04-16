#if os(macOS)
import SheetMusicCore

/// Decompose a `NoteDuration` into its base note length plus augmentation
/// dots. The MSCX decoder bakes the dot count into `.fraction(...)`
/// (e.g. a dotted quarter becomes `.fraction(3/8)`), which loses the
/// original dot count — the UI needs that count back to draw the dot
/// glyphs and to pick the correct notehead / flag for the base value.
@available(macOS 15.0, *)
enum DurationInterpretation {
    /// Split a duration into its (base, dots) form. For plain durations
    /// (`.whole`, `.half`, etc.) `dots` is 0. For a `.fraction` that
    /// matches the `numerator = 2^(dots+1) − 1, denominator = base × 2^dots`
    /// pattern, the original base + dots is returned. For anything else
    /// (e.g. tuplets like `.fraction(2/3)`) the original duration is
    /// returned with `dots = 0`.
    static func split(
        _ dur: NoteDuration
    ) -> (base: NoteDuration, dots: Int) {
        switch dur {
        case .whole, .half, .quarter, .eighth, .sixteenth,
             .thirtySecond, .sixtyFourth,
             .oneTwentyEighth, .twoFiftySixth:
            return (dur, 0)
        case .fraction(let f):
            guard f.numerator > 0, f.denominator > 0 else {
                return (dur, 0)
            }
            // numerator = 2^(dots+1) − 1 iterates as 1, 3, 7, 15, 31…
            var dots = 0
            var testN = 1
            while testN < f.numerator {
                dots += 1
                testN = (testN << 1) | 1
            }
            guard testN == f.numerator else { return (dur, 0) }
            let dotMultiplier = 1 << dots
            guard f.denominator % dotMultiplier == 0 else {
                return (dur, 0)
            }
            let baseDenom = f.denominator / dotMultiplier
            let base: NoteDuration
            switch baseDenom {
            case 1:   base = .whole
            case 2:   base = .half
            case 4:   base = .quarter
            case 8:   base = .eighth
            case 16:  base = .sixteenth
            case 32:  base = .thirtySecond
            case 64:  base = .sixtyFourth
            case 128: base = .oneTwentyEighth
            case 256: base = .twoFiftySixth
            default:  return (dur, 0)
            }
            return (base, dots)
        }
    }
}
#endif
