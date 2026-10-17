import SheetMusicFoundation

/// The per-bar facts of one staff, built in a single pass so a whole-score format does not rescan the staff for
/// every bar.
struct FormatRhythmsBars {
    let meters: [TimeSignature]
    let barTicks: [Int]
    let isPickup: [Bool]
    let division: Int

    init(staff: Staff, division: Int) {
        self.division = division
        let lengths = staff.measures.effectiveMeasureDurations().map { $0.ticks(division: division) }
        var meters: [TimeSignature] = []
        var current = TimeSignature(numerator: 4, denominator: 4)
        for measure in staff.measures {
            if let declared = measure.declaredTimeSignature { current = declared }
            meters.append(current)
        }
        self.meters = meters
        barTicks = lengths
        isPickup = staff.measures.indices.map { index in
            let nominal = Fraction(numerator: meters[index].numerator, denominator: meters[index].denominator)
                .ticks(division: division)
            guard lengths[index] < nominal else { return false }
            return index == 0 || staff.measures[index].irregular || staff.measures[index - 1].sectionBreak
        }
    }

    /// `nil` when the bar has no usable length or an empty window (nothing to format).
    func facts(at index: Int, window: Range<Int>?, protectedOnsets: Set<Int>) -> FormatRhythmsBarFacts? {
        guard barTicks.indices.contains(index), barTicks[index] > 0, !(window?.isEmpty ?? false) else {
            return nil
        }
        return FormatRhythmsBarFacts(
            meterNumerator: meters[index].numerator, meterDenominator: meters[index].denominator,
            barTicks: barTicks[index], isPickup: isPickup[index], division: division,
            window: window, protectedOnsets: protectedOnsets,
        )
    }
}

/// The onsets, per staff-bar, that a slur ends on or a lyric melisma targets — collected once per plan over the whole
/// score and voice-agnostic, so a chord in one voice is never folded into a chain at an onset some other voice's
/// marking lands on. Conservative on purpose: protecting too much only leaves a chain as written.
enum FormatRhythmsProtectedOnsets {
    struct Bar: Hashable {
        let staff: StaffAddress
        let measure: Int
    }

    static func collect(in score: Score) -> [Bar: Set<Int>] {
        var result: [Bar: Set<Int>] = [:]
        let division = score.division
        for (address, staff) in score.allStaves {
            let fractions = staff.measures.effectiveMeasureDurations()
            let lengths = fractions.map { $0.ticks(division: division) }
            func protect(measure: Int, tick: Int) {
                guard let landing = roll(measure: measure, tick: tick, lengths: lengths) else { return }
                result[Bar(staff: address, measure: landing.measure), default: []].insert(landing.tick)
            }
            for (measureIndex, measure) in staff.measures.enumerated() {
                for voice in measure.voices {
                    var tick = 0
                    for element in voice.elements {
                        defer { tick += element.cursorAdvance(division: division, in: fractions[measureIndex]) }
                        guard case let .chord(chord) = element else { continue }
                        for spanner in chord.spanners where spanner.kind == .slur {
                            // `Spanner+Offsets`: the end sits `nextMeasuresOffset` bars on, at the start's own bar
                            // tick plus the fraction.
                            let fraction = spanner.nextFractionsOffset?.ticks(division: division) ?? 0
                            // Clamped to the staff so a malformed offset cannot overflow the sum.
                            let offset = min(max(0, spanner.nextMeasuresOffset), lengths.count)
                            protect(measure: measureIndex + offset, tick: tick + fraction)
                        }
                        for lyric in chord.lyrics where lyric.ticks > 0 {
                            protect(measure: measureIndex, tick: tick + lyric.ticks)
                        }
                    }
                }
            }
        }
        return result
    }

    /// The bar and bar-relative tick that `measure` + `tick` names once the tick is walked through the bar lines on
    /// either side. `nil` past the end of the staff, including for a malformed `measure` that starts outside it.
    static func roll(measure: Int, tick: Int, lengths: [Int]) -> (measure: Int, tick: Int)? {
        guard lengths.indices.contains(measure) else { return nil }
        var measure = measure
        var tick = tick
        while tick < 0, measure > 0 {
            measure -= 1
            tick += lengths[measure]
        }
        while measure < lengths.count, tick >= lengths[measure] {
            tick -= lengths[measure]
            measure += 1
        }
        guard lengths.indices.contains(measure), tick >= 0 else { return nil }
        return (measure, tick)
    }
}
