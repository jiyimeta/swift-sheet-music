/// Spells a stretch of time as note or rest durations that respect the meter, without changing how long it sounds.
///
/// This is MuseScore's metric splitter (the algorithm behind its "regroup rhythms"), re-expressed over tick counts,
/// with three of its decisions exposed as `RhythmSpellingPolicy` knobs. It is a pure function of one span: the
/// caller decides what a span IS (which notes tie into one, which rests run together) and lays the answer out.
public enum RhythmSpelling {
    /// Spells one span. `start` and `length` are ticks from the bar's NOTIONAL start (the caller has already added a
    /// pickup's offset). `.keepWritten` is read as `.split` here — it is a span-level rule, applied by the caller.
    ///
    /// Rests carry at most one dot whatever `policy.dotLevel` says. A rest that is exactly one bar long, starts the
    /// bar and is not a pickup answers `[.measure]`; `isPickup` only disables that answer.
    ///
    /// Answers `[]` when the spelled values do not add up to `length` exactly; the caller keeps the span as written.
    ///
    /// A span that starts or ends on a position the dUnit cannot halve evenly down to (a third of a dUnit, say) is
    /// not judged against the meter at all and is spelled greedily, longest value first.
    public static func durations(
        forTicks length: Int, startingAt start: Int, isRest: Bool,
        meterNumerator: Int, meterDenominator: Int, barTicks: Int, isPickup: Bool,
        policy: RhythmSpellingPolicy, division: Int,
    ) -> [NoteDuration] {
        if isRest, length == barTicks, start == 0, !isPickup { return [.measure] }
        var splitter = RhythmSplitter(
            meter: RhythmMeter(numerator: meterNumerator, denominator: meterDenominator, division: division),
            policy: policy, wholeTicks: 4 * division, isRest: isRest,
        )
        if splitter.meter.isCompound {
            splitter.splitCompound(length: length, start: start)
        } else {
            splitter.populate(length: length, start: start)
        }
        // A span the values cannot cover to the tick (a non-tuplet third of a whole leaves a few ticks below a 256th)
        // would come back shorter than it went in. Answer nothing instead, so the caller carries the span as written.
        let measure = Fraction(ticks: barTicks, division: division)
        let spelled = splitter.result.reduce(0) { $0 + $1.resolved(in: measure).ticks(division: division) }
        return spelled == length ? splitter.result : []
    }
}

/// One run of the splitter over one span. Positions and lengths are ticks.
private struct RhythmSplitter {
    let meter: RhythmMeter
    let policy: RhythmSpellingPolicy
    let wholeTicks: Int
    let isRest: Bool
    var result: [NoteDuration] = []

    // MARK: Knobs

    /// Notes may carry `dotLevel` dots; rests are capped at one.
    private var maxDots: Int {
        isRest ? min(policy.dotLevel.rawValue, 1) : policy.dotLevel.rawValue
    }

    private var allowsMidBarSyncopation: Bool {
        policy.midBarSyncopations == .allow
    }

    private var restsMayCrossBeats: Bool {
        policy.beatCrossingRests == .allow
    }

    // MARK: Plain values

    /// A base value (`type` 0 is a whole, 1 a half, … 8 a 256th) carrying `dots` dots.
    private struct Value {
        var type: Int
        var dots: Int
    }

    private static let bases: [NoteDuration] = [
        .whole, .half, .quarter, .eighth, .sixteenth, .thirtySecond, .sixtyFourth, .oneTwentyEighth, .twoFiftySixth,
    ]

    private func fits(_ value: Value, in ticks: Int) -> Bool {
        wholeTicks * ((1 << (value.dots + 1)) - 1) <= ticks << (value.dots + value.type)
    }

    private func isExactly(_ value: Value, _ ticks: Int) -> Bool {
        wholeTicks * ((1 << (value.dots + 1)) - 1) == ticks << (value.dots + value.type)
    }

    private func ticks(of value: Value) -> Int {
        (wholeTicks * ((1 << (value.dots + 1)) - 1)) >> (value.dots + value.type)
    }

    private func duration(of value: Value) -> NoteDuration {
        Self.bases[value.type].dotted(value.dots)
    }

    /// The longest value, starting no larger than `fromType`, that fits inside `ticks` with at most `maxDots` dots.
    /// The largest base value is a whole (there is no breve): a span of two wholes or more is therefore spelled with
    /// undotted wholes.
    private func longestFit(_ ticks: Int, maxDots: Int, fromType: Int = 0) -> Value? {
        for type in fromType ... Self.bases.count - 1 {
            let dotCeiling = (type == 0 && ticks >= 2 * wholeTicks) ? 0 : maxDots
            for dots in stride(from: dotCeiling, through: 0, by: -1) {
                let value = Value(type: type, dots: dots)
                if fits(value, in: ticks) { return value }
            }
        }
        return nil
    }

    /// A single undotted value of exactly this length.
    private func isPlain(_ ticks: Int) -> Bool {
        guard let value = longestFit(ticks, maxDots: 0) else { return false }
        return isExactly(value, ticks)
    }

    /// Greedy, longest value first. The fallback for a span the meter cannot judge, and for the tail of a span that
    /// no single value covers.
    private mutating func appendGreedy(_ ticks: Int, maxDots: Int) {
        var remaining = ticks
        var value = longestFit(remaining, maxDots: maxDots)
        while let current = value, remaining > 0 {
            result.append(duration(of: current))
            remaining -= self.ticks(of: current)
            value = remaining > 0 ? longestFit(remaining, maxDots: maxDots, fromType: current.type) : nil
        }
    }

    // MARK: Compound meters

    /// In compound time a span that starts or ends off a beat is first cut at the beat, so each side is judged on
    /// its own.
    mutating func splitCompound(length: Int, start: Int) {
        let end = start + length
        let startBeat = meter.beatType(at: start)
        let endBeat = meter.beatType(at: end)
        if startBeat > .compoundUnstressed {
            let toBeat = meter.ticksToNextBeat(start)
            if end - start > toBeat {
                populate(length: toBeat, start: start)
                splitCompound(length: length - toBeat, start: start + toBeat)
                return
            }
        }
        if endBeat > .compoundUnstressed {
            let pastBeat = meter.ticksPastBeat(end)
            if end - start > pastBeat {
                populate(length: length - pastBeat, start: start)
                populate(length: pastBeat, start: end - pastBeat)
                return
            }
        }
        populate(length: length, start: start)
    }

    // MARK: The splitter

    mutating func populate(length: Int, start: Int) {
        let end = start + length
        let startLevel = meter.subbeatLevel(at: start)
        let endLevel = meter.subbeatLevel(at: end)
        let (crossedLevel, subbeatSplit) = meter.strongestSubbeatLevel(from: start, to: end)
        if startLevel < 0 || endLevel < 0 || crossedLevel < 0 {
            appendGreedy(length, maxDots: maxDots)
            return
        }

        // Sub-beat stage: a span that reaches a finer position at both ends than the coarsest boundary it crosses
        // must split at that boundary. This stage ignores whether the span is a rest.
        var mustSplit = crossedLevel < startLevel && crossedLevel < endLevel
        if startLevel == endLevel, crossedLevel == startLevel - 1 { mustSplit = false }
        // MuseScore's "level - 2" check. It is dead code there — it never produces a split that the stages around
        // it would not — and is ported as written so the port stays line-for-line.
        if startLevel == endLevel, crossedLevel == startLevel - 2 {
            mustSplit = meter.ticksToNextSubbeat(start, level: startLevel - 1)
                != meter.ticksPastSubbeat(start, level: startLevel - 1)
        }

        var split = subbeatSplit

        // Beat stage: only when the sub-beat stage did not split and the span crosses a dUnit.
        if !mustSplit, crossedLevel == 0 {
            let startBeat = meter.beatType(at: start)
            let endBeat = meter.beatType(at: end)
            let (strongest, dUnitsCrossed, beatSplit) = meter.strongestBeat(
                from: start, to: end, savingLast: startBeat <= .simpleUnstressed,
            )
            if let beatSplit { split = beatSplit }
            mustSplit = forcesSplit(
                length: length, startBeat: startBeat, endBeat: endBeat,
                dUnits: dUnitsCrossed, strongest: strongest,
            )
        }

        if !mustSplit, let value = longestFit(length, maxDots: maxDots), isExactly(value, length) {
            result.append(duration(of: value))
            return
        }
        guard let split, start < split, split < end else {
            appendGreedy(length, maxDots: maxDots)
            return
        }
        populate(length: split - start, start: start)
        populate(length: end - split, start: split)
    }

    // MARK: Beat-stage rules

    private func forcesSplit(
        length: Int, startBeat: RhythmMeter.BeatType, endBeat: RhythmMeter.BeatType,
        dUnits: Int, strongest: RhythmMeter.BeatType,
    ) -> Bool {
        if strongest <= .simpleStressed, !meter.isTriple, !meter.isDuple { return true }
        var treatAsRest = isRest
        if isRest, strongest <= .simpleUnstressed, meter.numerator == 2 || meter.isTriple {
            // A rest crossing an unstressed beat in 2- or 3-beat time splits, unless the knob lets it stay as one
            // undotted value — and then it is judged by the rules for notes.
            if !(restsMayCrossBeats && isPlain(length)) { return true }
            treatAsRest = false
        }
        if meter.isCompound {
            return forcesCompound(
                isRest: treatAsRest, length: length, startBeat: startBeat, endBeat: endBeat,
                dUnits: dUnits, strongest: strongest,
            )
        }
        return forcesSimple(
            isRest: treatAsRest, length: length, startBeat: startBeat, endBeat: endBeat,
            beats: dUnits, strongest: strongest,
        )
    }

    private func forcesCompound(
        isRest: Bool, length: Int, startBeat: RhythmMeter.BeatType, endBeat: RhythmMeter.BeatType,
        dUnits: Int, strongest: RhythmMeter.BeatType,
    ) -> Bool {
        switch strongest {
        case .compoundStressed:
            return forcesSimple(
                isRest: isRest, length: length, startBeat: startBeat, endBeat: endBeat,
                beats: dUnits / 3, strongest: .simpleStressed,
            )
        case .compoundUnstressed:
            return false
        case .compoundSubbeat:
            if startBeat <= .compoundUnstressed, endBeat <= .compoundUnstressed { return false }
            if isRest, startBeat > .compoundUnstressed { return true }
            return forcesSimple(
                isRest: isRest, length: length, startBeat: startBeat, endBeat: endBeat,
                beats: dUnits, strongest: .simpleUnstressed,
            )
        default:
            return forcesSimple(
                isRest: isRest, length: length, startBeat: startBeat, endBeat: endBeat,
                beats: dUnits, strongest: strongest,
            )
        }
    }

    private func forcesSimple(
        isRest: Bool, length: Int, startBeat: RhythmMeter.BeatType, endBeat: RhythmMeter.BeatType,
        beats: Int, strongest: RhythmMeter.BeatType,
    ) -> Bool {
        switch strongest {
        case .simpleStressed:
            if isRest { return true }
            if allowsMidBarSyncopation {
                if startBeat <= .simpleStressed || endBeat <= .simpleStressed { return false }
                if startBeat <= .simpleUnstressed, endBeat <= .simpleUnstressed { return false }
                return true
            }
            // folino: the note must start on a beat AND touch a stressed one.
            return !(startBeat <= .simpleUnstressed && (startBeat <= .simpleStressed || endBeat <= .simpleStressed))
        case .simpleUnstressed:
            if startBeat <= .simpleStressed, endBeat <= .simpleStressed { return false }
            if startBeat == .subbeat || endBeat == .subbeat {
                if beats > 1 { return true }
                if isRest { return !(restsMayCrossBeats && isPlain(length)) }
                return false
            }
            return false
        default:
            return false
        }
    }
}
