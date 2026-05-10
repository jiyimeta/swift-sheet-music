import SheetMusicCore

/// Decompose a `NoteDuration` into its base note length plus augmentation
/// dots. The MSCX decoder bakes the dot count into `.fraction(...)`
/// (e.g. a dotted quarter becomes `.fraction(3/8)`) and scales tuplet
/// members by the tuplet ratio (e.g. a triplet 8th becomes
/// `.fraction(1/12)`) — both lose the original visual base that the
/// UI needs to pick a notehead, beam level, flag, or dot count.
@available(macOS 15.0, iOS 16.0, *)
public enum DurationInterpretation {
    /// Split a duration into its (base, dots) form.
    ///
    /// - Plain durations (`.whole`, `.half`, …) → `(dur, 0)`.
    /// - `.fraction` that matches
    ///   `numerator = 2^(dots+1) − 1, denominator = base × 2^dots`
    ///   (i.e. "base ± dots") → `(base, dots)`.
    /// - `.fraction` that matches a known tuplet un-scaling of the
    ///   above (triplet ÷ 2/3, quintuplet ÷ 4/5, septuplet ÷ 4/7, …)
    ///   → `(base, dots)` of the un-scaled duration, so a triplet 8th
    ///   renders as an 8th (beams / flags included).
    /// - Anything else → `(dur, 0)`.
    public static func split(
        _ dur: NoteDuration
    ) -> (base: NoteDuration, dots: Int) {
        switch dur {
        case .whole, .half, .quarter, .eighth, .sixteenth,
             .thirtySecond, .sixtyFourth,
             .oneTwentyEighth, .twoFiftySixth:
            return (dur, 0)
        case let .fraction(f):
            if let direct = baseAndDots(
                numerator: f.numerator,
                denominator: f.denominator
            ) {
                return direct
            }
            // Reduced denominators that are powers of two encode
            // regular (non-tuplet) durations — full-measure and
            // pre-collapsed multi-measure rests written as
            // `<duration>N/4>` land here. Tuplet scaling these
            // produces false-positive dotted matches: e.g. `8/4`
            // (= 2 wholes, the rest body of a 2-bar mmRest) is
            // spuriously read as a *double-dotted whole* via the
            // 7/8 septuplet scale. Render them as a plain whole
            // rest, matching MuseScore's full-measure-rest
            // convention.
            let g = gcd(f.numerator, f.denominator)
            if f.denominator > 0,
               isPowerOfTwo(f.denominator / g)
            {
                return (.whole, 0)
            }
            // Common tuplet ratios (actual:normal). A triplet has 3
            // notes in the time of 2, so each note is scaled by 2/3 —
            // we reverse that by multiplying by 3/2. More exotic
            // ratios are tried in decreasing order of commonness.
            let tupletScales: [(num: Int, den: Int)] = [
                (3, 2), // triplet — 3 in 2
                (5, 4), // quintuplet — 5 in 4
                (6, 4), // sextuplet — 6 in 4
                (7, 4), // septuplet — 7 in 4
                (7, 8), // septuplet — 7 in 8
                (9, 8), // nonuplet
                (5, 2), // 5 in 2
                (11, 8), // 11 in 8
                (13, 8), // 13 in 8
            ]
            for scale in tupletScales {
                let num = f.numerator * scale.num
                let den = f.denominator * scale.den
                if let match = baseAndDots(
                    numerator: num, denominator: den
                ) {
                    return match
                }
            }
            return (dur, 0)
        }
    }

    /// Attempt to read `numerator/denominator` as a dotted base
    /// duration. Returns nil for anything that isn't
    /// `2^(d+1)−1 / base×2^d` (after gcd reduction).
    private static func baseAndDots(
        numerator: Int, denominator: Int
    ) -> (base: NoteDuration, dots: Int)? {
        guard numerator > 0, denominator > 0 else { return nil }
        let g = gcd(numerator, denominator)
        let n = numerator / g
        let d = denominator / g
        // n must be 2^(dots+1) − 1
        var dots = 0
        var testN = 1
        while testN < n {
            dots += 1
            testN = (testN << 1) | 1
        }
        guard testN == n else { return nil }
        let dotMultiplier = 1 << dots
        guard d % dotMultiplier == 0 else { return nil }
        let baseDenom = d / dotMultiplier
        let base: NoteDuration
        switch baseDenom {
        case 1: base = .whole
        case 2: base = .half
        case 4: base = .quarter
        case 8: base = .eighth
        case 16: base = .sixteenth
        case 32: base = .thirtySecond
        case 64: base = .sixtyFourth
        case 128: base = .oneTwentyEighth
        case 256: base = .twoFiftySixth
        default: return nil
        }
        return (base, dots)
    }

    private static func isPowerOfTwo(_ n: Int) -> Bool {
        n > 0 && (n & (n - 1)) == 0
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = abs(a)
        var b = abs(b)
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return a
    }
}
