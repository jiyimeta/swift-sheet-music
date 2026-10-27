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
    /// Its length is heard (§4.4): it lasts `ticks` and is written as `written`, the length and value of the source
    /// chord that makes it heard. When the voice cannot give it that, the bar is left as written for `reason`.
    case fixed(ticks: Int, written: NoteDuration, reason: RevoiceKeepReason)
}

extension RevoiceBarPlanner {
    /// One target voice's chords laid out across the bar (design §4.2, §4.4, §4.5).
    ///
    /// A drum hit's written length says nothing about how it sounds, so a free chord at `o` lasts until the next
    /// boundary of its voice (its next onset, the start of the next tuplet the voice carries, or the next tick an
    /// annotation of the voice stands at; the bar's end for the last) or until `max(o + the longest source length
    /// among its hits, the next beat after o)`, whichever comes first. That span is written as ONE value, the first
    /// `RhythmSpelling` gives for it, never a tie, and the chord lasts as long as that value. A fixed chord keeps its
    /// length and value unchanged, and the voice's next onset must not fall before it ends — no other hit of the
    /// voice, and no tuplet it carries, may start inside a roll or a tied note. An annotation inside one is
    /// `voiceWrite`'s to refuse.
    ///
    /// A tuplet the voice carries (`units`, from `tupletUnits`) is laid out whole, one slot per member
    /// (`memberSlots`), and the chords inside it are its members; §4.2's extension never enters it.
    ///
    /// The time a chord or tuplet leaves before the next boundary, and the time before the voice's first one, is rest
    /// spelled by the meter under `policy`, split at the voice's annotation ticks so each annotation finds a slot
    /// starting where it stands; a voice with no chord is one span of rest, which a full bar spells as a measure
    /// rest. Beats and spellings are read in the notional bar, a pickup's offset added. Fails with the reason a chord
    /// cannot keep the length that is heard, and with `.unspellable` when the meter cannot spell a span to the tick.
    static func timeline(
        of chords: [RevoiceTargetChord], units: [RevoiceTupletUnit], voiceIndex: Int, in bar: RevoiceBar,
        sources: SourceIndex, landings: RevoiceLandings, policy: RhythmSpellingPolicy,
    ) -> Result<[RevoiceTimedSlot], RevoiceKeepReason> {
        let speller = RevoiceSpeller(meter: bar.meter, policy: policy, cuts: landings.annotationTicks(of: voiceIndex))
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
                    landings: landings,
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
                    chord, before: boundary, voiceIndex: voiceIndex, sources: sources, landings: landings,
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
        // `timelinePieces` takes every chord outside the carried tuplets and `memberSlots` only the chords on member
        // onsets; `tupletUnits` refuses a chord between members, so each chord lands exactly once.
        assert(
            slots.compactMap { $0.chord?.onset } == chords.map(\.onset),
            "a chord of the voice was laid out other than once: inside a carried tuplet but off its members",
        )
        return .success(slots)
    }

    /// A chord outside every tuplet its voice carries, laid out from its onset to at most `boundary` (§4.2, §4.4):
    /// its slot, and the tick it ends at. A fixed chord's value must be one a plain chord can be written as — a
    /// tuplet member's scaled value or a measure rest's marker, which a fermata or a grace can hand a chord outside
    /// any tuplet, cannot.
    private static func layOut(
        _ chord: RevoiceTargetChord, before boundary: Int, voiceIndex: Int, sources: SourceIndex,
        landings: RevoiceLandings, speller: RevoiceSpeller,
    ) -> Result<(slot: RevoiceTimedSlot, end: Int), RevoiceKeepReason> {
        switch chordLength(of: chord, voiceIndex: voiceIndex, sources: sources, landings: landings) {
        case let .failure(reason):
            return .failure(reason)
        case let .success(.fixed(ticks, written, reason)):
            guard chord.onset + ticks <= boundary, written.baseAndDots() != nil else { return .failure(reason) }
            let timed = RevoiceTimedSlot(onset: chord.onset, duration: written, chord: chord)
            return .success((slot: timed, end: chord.onset + ticks))
        case .success(.free):
            let longest = chord.sources.compactMap { sources[$0]?.length }.max() ?? 0
            let reach = min(boundary, speller.nextCut(after: chord.onset) ?? boundary)
            let end = min(reach, chord.onset + max(longest, speller.ticksToNextBeat(chord.onset)))
            let spelled = speller.durations(forTicks: end - chord.onset, at: chord.onset, isRest: false)
            guard let written = spelled.first else { return .failure(.unspellable) }
            let timed = RevoiceTimedSlot(onset: chord.onset, duration: written, chord: chord)
            return .success((slot: timed, end: chord.onset + speller.ticks(of: written)))
        }
    }

    /// The length `chord` keeps in voice `voiceIndex` (design §4.4). A hit fixes it when its note is tied either way
    /// — a tie must end exactly where its partner starts — or when its source chord rolls, since a roll lasts its
    /// written length, or spreads an arpeggio, whose notes are timed across it (`MidiRenderer.arpeggioNoteEvents`).
    /// Whatever rides on the chord fixes it too (`RevoiceLandings.keptLengths`): graces that sound in its time and a
    /// fermata that holds it. Fails when the chord cannot keep one length — those that fix it differ, or a duplicate
    /// it drops (two voices sounding one drum at once) differs in its ties from the note it keeps — with the reason of
    /// what rides on it when that is what differs, `.audibleLength` otherwise.
    static func chordLength(
        of chord: RevoiceTargetChord, voiceIndex: Int, sources: SourceIndex, landings: RevoiceLandings,
    ) -> Result<RevoiceChordLength, RevoiceKeepReason> {
        let keepsEveryTie = chord.incoming.allSatisfy { hit in
            chord.hits.contains { kept in
                kept.pitch == hit.pitch && kept.note.tieForward == hit.note.tieForward
                    && kept.note.tieBack == hit.note.tieBack
            }
        }
        guard keepsEveryTie else { return .failure(.audibleLength) }
        let heard = chord.incoming.compactMap { hit -> RevoiceLandings.KeptLength? in
            guard let source = sources[hit.source] else { return nil }
            let isTied = hit.note.tieForward != nil || hit.note.tieBack != nil
            let rolls = source.chord.tremolo?.span == .single
            let spreads = source.chord.arpeggio != nil
            guard isTied || rolls || spreads else { return nil }
            return RevoiceLandings.KeptLength(
                ticks: source.length, written: source.chord.duration, reason: .audibleLength,
            )
        }
        let kept = heard + landings.keptLengths(at: voiceIndex, onset: chord.onset)
        guard let first = kept.first else { return .success(.free) }
        if let other = kept.first(where: { $0.ticks != first.ticks }) {
            return .failure(other.reason == .audibleLength ? first.reason : other.reason)
        }
        return .success(.fixed(ticks: first.ticks, written: first.written, reason: first.reason))
    }
}

/// `RhythmSpelling` over one bar under the user's policy. Positions are bar-relative, counted from the bar's first
/// element, and read in the notional bar — a pickup's offset added — as `FormatRhythms` reads them.
private struct RevoiceSpeller {
    let meter: BarMeter
    let policy: RhythmSpellingPolicy
    let beats: RhythmMeter
    /// The ticks the voice's annotations stand at, ascending: a free chord ends by the next one, and rest is split
    /// at each.
    let cuts: [Int]

    /// The caller has checked the meter is readable (`RevoiceBar.isMeterReadable`).
    init(meter: BarMeter, policy: RhythmSpellingPolicy, cuts: [Int]) {
        self.meter = meter
        self.policy = policy
        self.cuts = cuts
        beats = RhythmMeter(numerator: meter.numerator, denominator: meter.denominator, division: meter.division)
    }

    /// Ticks from `rtick` to the next beat as `RhythmMeter` reads the meter — a quarter in 4/4, a dotted quarter in
    /// 6/8. A position on a beat is a whole beat from the next.
    func ticksToNextBeat(_ rtick: Int) -> Int {
        beats.ticksToNextBeat(rtick + meter.pickupOffset)
    }

    /// The first annotation tick after `rtick`, nil when none follows.
    func nextCut(after rtick: Int) -> Int? {
        cuts.first { $0 > rtick }
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

    /// Appends the rests that fill `start ..< end` — nothing for an empty span — each piece between two annotation
    /// ticks spelled on its own, and answers whether the meter could spell them to the tick.
    func appendRests(from start: Int, to end: Int, into slots: inout [RevoiceTimedSlot]) -> Bool {
        let bounds = [start] + cuts.filter { start < $0 && $0 < end } + [end]
        for (from, to) in zip(bounds, bounds.dropFirst()) where from != to {
            let rests = durations(forTicks: to - from, at: from, isRest: true)
            guard !rests.isEmpty else { return false }
            var onset = from
            for rest in rests {
                slots.append(RevoiceTimedSlot(onset: onset, duration: rest, chord: nil))
                onset += ticks(of: rest)
            }
        }
        return true
    }
}
