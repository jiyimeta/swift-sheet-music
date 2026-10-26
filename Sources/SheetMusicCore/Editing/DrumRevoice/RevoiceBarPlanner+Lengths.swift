/// A slot of one rewritten voice before its identity is settled: where it starts, the value it is written as, and
/// the chord it holds — nil for a rest.
struct RevoiceTimedSlot {
    let onset: Int
    let duration: NoteDuration
    let chord: RevoiceTargetChord?
}

extension RevoiceBarPlanner {
    /// One target voice's chords laid out across the bar (design §4.2). A drum hit's written length says nothing
    /// about how it sounds, so a chord at `o` lasts until the next boundary of its voice (its next onset; the bar's
    /// end for the last) or until `max(o + the longest source length among its hits, the next beat after o)`,
    /// whichever comes first. That span is written as ONE value, the first `RhythmSpelling` gives for it, never a
    /// tie, and the chord lasts as long as that value. The time a chord leaves before the next boundary, and the time
    /// before the voice's first chord, is rest spelled by the meter under `policy`; a voice with no chord is one span
    /// of rest, which a full bar spells as a measure rest. Beats and spellings are read in the notional bar, a
    /// pickup's offset added. Nil when the meter cannot spell a span to the tick.
    static func timeline(
        of chords: [RevoiceTargetChord], in bar: RevoiceBar, sources: SourceIndex, policy: RhythmSpellingPolicy,
    ) -> [RevoiceTimedSlot]? {
        let speller = RevoiceSpeller(meter: bar.meter, policy: policy)
        var slots: [RevoiceTimedSlot] = []
        var cursor = 0
        for (index, chord) in chords.enumerated() {
            guard speller.appendRests(from: cursor, to: chord.onset, into: &slots) else { return nil }
            let boundary = chords.indices.contains(index + 1) ? chords[index + 1].onset : bar.meter.barTicks
            let longest = chord.sources.compactMap { sources[$0]?.length }.max() ?? 0
            let end = min(boundary, chord.onset + max(longest, speller.ticksToNextBeat(chord.onset)))
            let spelled = speller.durations(forTicks: end - chord.onset, at: chord.onset, isRest: false)
            guard let written = spelled.first else { return nil }
            slots.append(RevoiceTimedSlot(onset: chord.onset, duration: written, chord: chord))
            cursor = chord.onset + speller.ticks(of: written)
        }
        guard speller.appendRests(from: cursor, to: bar.meter.barTicks, into: &slots) else { return nil }
        return slots
    }
}

/// `RhythmSpelling` over one bar under the user's policy. Positions are bar-relative, counted from the bar's first
/// element, and read in the notional bar — a pickup's offset added — as `FormatRhythms` reads them.
private struct RevoiceSpeller {
    let meter: BarMeter
    let policy: RhythmSpellingPolicy
    let beats: RhythmMeter

    /// The caller has checked the meter is readable (`RevoiceBar.isMeterReadable`).
    init(meter: BarMeter, policy: RhythmSpellingPolicy) {
        self.meter = meter
        self.policy = policy
        beats = RhythmMeter(numerator: meter.numerator, denominator: meter.denominator, division: meter.division)
    }

    /// Ticks from `rtick` to the next beat as `RhythmMeter` reads the meter — a quarter in 4/4, a dotted quarter in
    /// 6/8. A position on a beat is a whole beat from the next.
    func ticksToNextBeat(_ rtick: Int) -> Int {
        beats.ticksToNextBeat(rtick + meter.pickupOffset)
    }

    func durations(forTicks ticks: Int, at rtick: Int, isRest: Bool) -> [NoteDuration] {
        RhythmSpelling.durations(
            forTicks: ticks, startingAt: rtick + meter.pickupOffset, isRest: isRest,
            meterNumerator: meter.numerator, meterDenominator: meter.denominator, barTicks: meter.barTicks,
            isPickup: meter.isPickup, policy: policy, division: meter.division,
        )
    }

    /// The ticks `duration` lasts in this bar; a measure rest lasts the bar.
    func ticks(of duration: NoteDuration) -> Int {
        let bar = Fraction(ticks: meter.barTicks, division: meter.division)
        return duration.resolved(in: bar).ticks(division: meter.division)
    }

    /// Appends the rests that fill `start ..< end` — nothing for an empty span — and answers whether the meter could
    /// spell them to the tick.
    func appendRests(from start: Int, to end: Int, into slots: inout [RevoiceTimedSlot]) -> Bool {
        guard start != end else { return true }
        let rests = durations(forTicks: end - start, at: start, isRest: true)
        guard !rests.isEmpty else { return false }
        var onset = start
        for rest in rests {
            slots.append(RevoiceTimedSlot(onset: onset, duration: rest, chord: nil))
            onset += ticks(of: rest)
        }
        return true
    }
}
