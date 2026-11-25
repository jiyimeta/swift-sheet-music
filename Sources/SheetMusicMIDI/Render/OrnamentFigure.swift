import SheetMusicCore

/// The notes an ornament is played as, in staff steps from the written note: 0 the note itself, 1 its upper neighbor,
/// -1 its lower one. What MuseScore 4's playback plays (`OrnamentsRenderer`'s disclosure rules); its MIDI export has a
/// table of its own, which this does not follow.
struct OrnamentFigure: Equatable, Sendable {
    /// Played once, at the start and at the end.
    var prefix: [Int] = []
    var suffix: [Int] = []
    /// What fills the time between them: over and over for a trill, once — so `[0]` is the note held — otherwise.
    var body = [0]
    var repeatsBody = false
    var pace: Pace

    /// How long one note of the figure is, in quarter notes, by tempo.
    struct Pace: Equatable, Sendable {
        /// Below 108 beats a minute; a chord no longer than this is played plain, at any tempo.
        var slow: Double
        /// From 108.
        var moderate: Double
        /// From 200.
        var fast: Double

        func quarters(atBeatsPerSecond bps: Double) -> Double {
            if bps >= 200.0 / 60 { return fast }
            return bps >= 108.0 / 60 ? moderate : slow
        }

        static let trill = Pace(slow: 1.0 / 20, moderate: 1.0 / 8, fast: 1.0 / 4)
        static let turn = Pace(slow: 1.0 / 16, moderate: 1.0 / 8, fast: 1.0 / 4)
        static let eighths = Pace(slow: 1.0 / 8, moderate: 1.0 / 8, fast: 1.0 / 8)
        static let quarters = Pace(slow: 1.0 / 4, moderate: 1.0 / 4, fast: 1.0 / 4)
    }

    /// One note of a played figure, as ticks from the chord's onset.
    struct SubNote: Equatable {
        var offset: Int
        var ticks: Int
        var step: Int
    }

    /// The figure spread over `totalTicks`. `nil` when the chord is too short to carry it: it is played plain.
    ///
    /// `isContinuing` plays a trill's later links under a tie, which carry the alternation on without starting over.
    ///
    /// A figure whose prefix and suffix would fill the chord is played evenly instead, each note once. MuseScore
    /// computes the repeats from the whole chord and can run such a figure past its end.
    func subNotes(
        totalTicks: Int, division: Int, beatsPerSecond: Double, isContinuing: Bool = false,
    ) -> [SubNote]? {
        guard Double(totalTicks) > pace.slow * Double(division) else { return nil }
        let noteTicks = pace.quarters(atBeatsPerSecond: beatsPerSecond) * Double(division)
        let prefix = isContinuing ? [] : prefix
        let prefixTicks = Int((Double(prefix.count) * noteTicks).rounded())
        let suffixTicks = Int((Double(suffix.count) * noteTicks).rounded())
        let bodyTicks = totalTicks - prefixTicks - suffixTicks
        let repeats = repeatsBody ? Int(Double(bodyTicks) / noteTicks / Double(body.count)) : 1
        if repeats < 1 || bodyTicks < body.count * max(1, Int(noteTicks / 2)) {
            let steps = prefix + body + suffix
            guard steps.count > 1, totalTicks >= steps.count else { return nil }
            return Self.even(steps, ticks: totalTicks, from: 0)
        }
        let bodySteps = Array(repeating: body, count: repeats).flatMap(\.self)
        return Self.even(prefix, ticks: prefixTicks, from: 0)
            + Self.even(bodySteps, ticks: bodyTicks, from: prefixTicks)
            + Self.even(suffix, ticks: suffixTicks, from: prefixTicks + bodyTicks)
    }

    /// `steps` sharing `ticks` evenly, rounded at the running edge so they fill it exactly.
    private static func even(_ steps: [Int], ticks: Int, from start: Int) -> [SubNote] {
        steps.indices.map { index in
            let from = index * ticks / steps.count
            return SubNote(offset: start + from, ticks: (index + 1) * ticks / steps.count - from, step: steps[index])
        }
    }
}

extension OrnamentFigure {
    /// What `ornament` is played as, or `nil` when it is not played: silenced by the user (`<play>`), or a symbol
    /// MuseScore gives no realization.
    static func figure(for ornament: ChordOrnament) -> OrnamentFigure? {
        guard ornament.plays ?? true else { return nil }
        let isBaroque = ornament.ornamentStyle == .baroque
        return switch ornament.kind {
        case .trill, .shake3, .shakeMuffat1: isBaroque ? trillBaroque : trill
        case .shortTrill: isBaroque ? upperMordentBaroque : upperMordent
        case .mordent, .pinceCouperin: lowerMordent
        case .turn, .turnUp, .haydn: turn
        case .turnInverted, .turnUpS, .turnSlash: invertedTurn
        case .tremblement, .tremblementCouperin: tremblement
        case .prallMordent: prallMordent
        case .upPrall: upPrall
        case .upMordent: upMordent
        case .downMordent: downMordent
        case .prallUp: prallUp
        case .prallDown: prallDown
        case .linePrall: linePrall
        case .precompMordentUpperPrefix, .precompSlide, .unknown: nil
        }
    }

    /// What every chord under a trill line is played as.
    static func figure(for line: TrillType) -> OrnamentFigure {
        switch line {
        case .trill: trill
        case .upprall: upPrall
        case .downprall: prallDown
        case .prallprall: linePrall
        }
    }

    static let trill = OrnamentFigure(body: [0, 1], repeatsBody: true, pace: .trill)
    static let trillBaroque = OrnamentFigure(suffix: [-1, 0], body: [1, 0], repeatsBody: true, pace: .trill)
    static let linePrall = OrnamentFigure(
        prefix: [2, 2, 2], suffix: [1, 0], body: [1, 0], repeatsBody: true, pace: .eighths,
    )
    static let upPrall = OrnamentFigure(
        prefix: [-1, 0], suffix: [1, 0], body: [1, 0], repeatsBody: true, pace: .eighths,
    )
    static let upMordent = OrnamentFigure(
        prefix: [-1, 0], suffix: [-1, 0], body: [1, 0], repeatsBody: true, pace: .quarters,
    )
    static let upperMordent = OrnamentFigure(prefix: [0, 1], pace: .turn)
    static let upperMordentBaroque = OrnamentFigure(prefix: [1, 0, 1], pace: .turn)
    static let lowerMordent = OrnamentFigure(prefix: [0, -1], pace: .turn)
    static let downMordent = OrnamentFigure(
        prefix: [1, 1, 1, 0], suffix: [-1, 0], body: [1, 0], repeatsBody: true, pace: .quarters,
    )
    static let prallUp = OrnamentFigure(
        prefix: [1, 0], suffix: [-1, 0], body: [1, 0], repeatsBody: true, pace: .quarters,
    )
    static let prallDown = OrnamentFigure(
        prefix: [1, 0], suffix: [-1, 0, 0, 0], body: [1, 0], repeatsBody: true, pace: .quarters,
    )
    static let turn = OrnamentFigure(prefix: [1, 0, -1], pace: .turn)
    static let invertedTurn = OrnamentFigure(prefix: [-1, 0, 1], pace: .turn)
    static let tremblement = OrnamentFigure(prefix: [1, 0], body: [1, 0], pace: .quarters)
    static let prallMordent = OrnamentFigure(body: [1, 0, -1, 0], pace: .quarters)
}

extension ChordOrnament.Interval {
    /// The semitones of a stated interval, or `nil` for `auto`, which the key and the bar's accidentals decide.
    var semitones: Int? {
        let (base, isPerfect) = switch step {
        case .unison: (0, true)
        case .second: (2, false)
        case .third: (4, false)
        case .fourth: (5, true)
        case .fifth: (7, true)
        case .sixth: (9, false)
        case .seventh: (11, false)
        case .octave: (12, true)
        }
        return switch quality {
        case .auto: nil
        case .major, .perfect: base
        case .minor: base - 1
        case .augmented: base + 1
        case .diminished: base - (isPerfect ? 1 : 2)
        }
    }

    /// The staff steps the interval spans.
    var staffSteps: Int {
        switch step {
        case .unison: 0
        case .second: 1
        case .third: 2
        case .fourth: 3
        case .fifth: 4
        case .sixth: 5
        case .seventh: 6
        case .octave: 7
        }
    }
}
