import SheetMusicFoundation

extension Chord {
    /// The value the chord is drawn as — its head, stem, flag, beams and dots: `duration`, or, for a chord written
    /// doubled (`isWrittenDoubled`), the next longer value with the same dots, `duration` read through any tuplet the
    /// way `DurationInterpretation` reads it. A value with nothing longer (`long`, a bare fraction) stays as it is.
    public var drawnDuration: NoteDuration {
        guard isWrittenDoubled else { return duration }
        let (base, dots) = DurationInterpretation.split(duration)
        guard let twice = base.twiceAsLong else { return duration }
        return twice.dotted(dots)
    }
}

extension NoteDuration {
    /// The base value twice as long as this one, nil for `long`, `measure` and a bare fraction.
    var twiceAsLong: NoteDuration? {
        switch self {
        case .breve: .long
        case .whole: .breve
        case .half: .whole
        case .quarter: .half
        case .eighth: .quarter
        case .sixteenth: .eighth
        case .thirtySecond: .sixteenth
        case .sixtyFourth: .thirtySecond
        case .oneTwentyEighth: .sixtyFourth
        case .twoFiftySixth: .oneTwentyEighth
        case .fiveHundredTwelfth: .twoFiftySixth
        case .oneThousandTwentyFourth: .fiveHundredTwelfth
        case .long, .measure, .fraction: nil
        }
    }
}
