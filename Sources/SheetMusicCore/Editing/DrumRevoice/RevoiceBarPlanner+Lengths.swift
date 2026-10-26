/// A slot of one rewritten voice before its identity is settled: where it starts, the value it is written as, the
/// chord it holds — nil for a rest — and the tuplet it is a member of, as an index into the voice's carried tuplets.
struct RevoiceTimedSlot {
    let onset: Int
    let duration: NoteDuration
    let chord: RevoiceTargetChord?
    let tuplet: Int?

    init(onset: Int, duration: NoteDuration, chord: RevoiceTargetChord?, tuplet: Int? = nil) {
        self.onset = onset
        self.duration = duration
        self.chord = chord
        self.tuplet = tuplet
    }
}

/// How long a chord of a rewritten voice lasts.
enum RevoiceChordLength: Equatable {
    /// Nothing makes its length heard, so the writer chooses it (design §4.2).
    case free
    /// A tie, a roll or after-graces make its length heard (§4.4): it lasts `ticks`, its source chord's length, and
    /// is written as `written`, its source chord's own value.
    case fixed(ticks: Int, written: NoteDuration)
}

extension RevoiceBarPlanner {
    /// One target voice's chords laid out across the bar (design §4.2, §4.4, §4.5).
    ///
    /// A drum hit's written length says nothing about how it sounds, so a free chord at `o` lasts until the next
    /// boundary of its voice (its next onset, or the start of the next tuplet the voice carries; the bar's end for
    /// the last) or until `max(o + the longest source length among its hits, the next beat after o)`, whichever comes
    /// first. That span is written as ONE value, the first `RhythmSpelling` gives for it, never a tie, and the chord
    /// lasts as long as that value. A fixed chord keeps its source length and value unchanged, and the voice's next
    /// boundary must not fall before it ends — no other hit of the voice, and no tuplet it carries, may start inside a
    /// roll or a tied note.
    ///
    /// A tuplet the voice carries (`units`, from `tupletUnits`) is laid out whole, one slot per member
    /// (`memberSlots`), and the chords inside it are its members; §4.2's extension never enters it.
    ///
    /// The time a chord or tuplet leaves before the next boundary, and the time before the voice's first one, is rest
    /// spelled by the meter under `policy`; a voice with no chord is one span of rest, which a full bar spells as a
    /// measure rest. Beats and spellings are read in the notional bar, a pickup's offset added. Fails with
    /// `.audibleLength` when a chord cannot keep the length that is heard, and with `.unspellable` when the meter
    /// cannot spell a span to the tick.
    static func timeline(
        of chords: [RevoiceTargetChord], units: [RevoiceTupletUnit], voiceIndex: Int, in bar: RevoiceBar,
        sources: SourceIndex, voiceForPitch: [Int: Int], policy: RhythmSpellingPolicy,
    ) -> Result<[RevoiceTimedSlot], RevoiceKeepReason> {
        let speller = RevoiceSpeller(meter: bar.meter, policy: policy)
        let pieces = timelinePieces(of: chords, units: units)
        var slots: [RevoiceTimedSlot] = []
        var cursor = 0
        for (index, piece) in pieces.enumerated() {
            guard speller.appendRests(from: cursor, to: piece.onset, into: &slots) else {
                return .failure(.unspellable)
            }
            switch piece {
            case let .tuplet(unit, unitIndex):
                let members = memberSlots(
                    of: unit, index: unitIndex, chords: chords, voiceIndex: voiceIndex, sources: sources,
                    voiceForPitch: voiceForPitch,
                )
                switch members {
                case let .success(laidOut):
                    slots += laidOut
                    cursor = unit.end
                case let .failure(reason):
                    return .failure(reason)
                }
            case let .chord(chord):
                let boundary = pieces.indices.contains(index + 1) ? pieces[index + 1].onset : bar.meter.barTicks
                let laidOut = layOut(
                    chord, before: boundary, voiceIndex: voiceIndex, sources: sources, voiceForPitch: voiceForPitch,
                    speller: speller,
                )
                switch laidOut {
                case let .success(timed):
                    slots.append(timed.slot)
                    cursor = timed.end
                case let .failure(reason):
                    return .failure(reason)
                }
            }
        }
        guard speller.appendRests(from: cursor, to: bar.meter.barTicks, into: &slots) else {
            return .failure(.unspellable)
        }
        return .success(slots)
    }

    /// A chord outside every tuplet its voice carries, laid out from its onset to at most `boundary` (§4.2, §4.4):
    /// its slot, and the tick it ends at.
    private static func layOut(
        _ chord: RevoiceTargetChord, before boundary: Int, voiceIndex: Int, sources: SourceIndex,
        voiceForPitch: [Int: Int], speller: RevoiceSpeller,
    ) -> Result<(slot: RevoiceTimedSlot, end: Int), RevoiceKeepReason> {
        switch chordLength(of: chord, voiceIndex: voiceIndex, sources: sources, voiceForPitch: voiceForPitch) {
        case nil:
            return .failure(.audibleLength)
        case let .fixed(ticks, written)?:
            guard chord.onset + ticks <= boundary else { return .failure(.audibleLength) }
            let timed = RevoiceTimedSlot(onset: chord.onset, duration: written, chord: chord)
            return .success((slot: timed, end: chord.onset + ticks))
        case .free?:
            let longest = chord.sources.compactMap { sources[$0]?.length }.max() ?? 0
            let end = min(boundary, chord.onset + max(longest, speller.ticksToNextBeat(chord.onset)))
            let spelled = speller.durations(forTicks: end - chord.onset, at: chord.onset, isRest: false)
            guard let written = spelled.first else { return .failure(.unspellable) }
            let timed = RevoiceTimedSlot(onset: chord.onset, duration: written, chord: chord)
            return .success((slot: timed, end: chord.onset + speller.ticks(of: written)))
        }
    }

    /// The length `chord` keeps in voice `voiceIndex` (design §4.4). A hit fixes it when its note is tied either way
    /// — a tie must end exactly where its partner starts — or when its source chord rolls, since a roll lasts its
    /// written length, or has after-graces that land in this voice, since they sound in their chord's tail. Nil when
    /// the chord cannot keep one: the hits that fix it come from chords of different lengths, or a duplicate it drops
    /// (two voices sounding one drum at once) differs in its ties from the note it keeps.
    static func chordLength(
        of chord: RevoiceTargetChord, voiceIndex: Int, sources: SourceIndex, voiceForPitch: [Int: Int],
    ) -> RevoiceChordLength? {
        let keepsEveryTie = chord.incoming.allSatisfy { hit in
            chord.hits.contains { kept in
                kept.pitch == hit.pitch && kept.note.tieForward == hit.note.tieForward
                    && kept.note.tieBack == hit.note.tieBack
            }
        }
        guard keepsEveryTie else { return nil }
        let fixing = chord.incoming.compactMap { hit -> RevoiceBar.SourceChord? in
            guard let source = sources[hit.source] else { return nil }
            let isTied = hit.note.tieForward != nil || hit.note.tieBack != nil
            let rolls = source.chord.tremolo?.span == .single
            let gracesHere = source.chord.graceNotesAfter.contains { grace in
                targetVoice(of: grace, in: voiceForPitch) == voiceIndex
            }
            return isTied || rolls || gracesHere ? source : nil
        }
        guard let first = fixing.first else { return .free }
        guard fixing.allSatisfy({ $0.length == first.length }) else { return nil }
        return .fixed(ticks: first.length, written: first.chord.duration)
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
