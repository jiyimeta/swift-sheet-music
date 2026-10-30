/// What `FormatRhythmsBarPlanner` knows about one bar-voice before it decides anything: where every element starts,
/// how long it is, which ones are tuplet members, and the predicates that decide what may be rewritten (spec §4.1, §4.2
/// and the span-level `keepWritten` rule of §3.2).
struct FormatRhythmsBarContext {
    let facts: FormatRhythmsBarFacts
    let policy: RhythmSpellingPolicy
    let elements: [VoiceElement]
    /// Bar-relative start of each element. A `.locationShift` moves the cursor, as everywhere else.
    let onsets: [Int]
    /// Length in ticks of each chord or rest; 0 for everything untimed.
    let lengths: [Int]
    let isTupletMember: [Bool]
    /// Chords that are the second half of a two-note (`.between`) tremolo.
    let tremoloFollowers: Set<Int>
    /// A pickup is right-aligned against its nominal bar.
    let pickupOffset: Int

    init(voice: Voice, facts: FormatRhythmsBarFacts, policy: RhythmSpellingPolicy) {
        self.facts = facts
        self.policy = policy
        elements = voice.elements.values
        let measureDuration = Fraction(ticks: facts.barTicks, division: facts.division)
        var cursor = 0
        var onsets: [Int] = []
        var lengths: [Int] = []
        for element in elements {
            onsets.append(cursor)
            if case let .chord(chord) = element {
                lengths.append(chord.duration.resolved(in: measureDuration).ticks(division: facts.division))
            } else {
                lengths.append(0)
            }
            cursor += element.cursorAdvance(division: facts.division, in: measureDuration)
        }
        self.onsets = onsets
        self.lengths = lengths
        var members = [Bool](repeating: false, count: elements.count)
        for span in voice.tupletSpans where span.startIndex >= 0 && span.endIndex < elements.count {
            for index in span.startIndex ... max(span.startIndex, span.endIndex) {
                members[index] = true
            }
        }
        isTupletMember = members
        var followers = Set<Int>()
        for (index, element) in elements.enumerated() {
            if case let .chord(chord) = element, chord.tremolo?.span == .between, index + 1 < elements.count {
                followers.insert(index + 1)
            }
        }
        tremoloFollowers = followers
        let nominal = facts.meterNumerator * 4 * facts.division / facts.meterDenominator
        pickupOffset = facts.isPickup ? max(0, nominal - facts.barTicks) : 0
    }

    // MARK: Candidates

    func chord(at index: Int) -> Chord? {
        if case let .chord(chord) = elements[index] { chord } else { nil }
    }

    /// A rest that is free to be merged: not in a tuplet and not a measure rest (which is never rewritten).
    func isRestCandidate(_ index: Int) -> Bool {
        guard let chord = chord(at: index), chord.notes.isEmpty, !isTupletMember[index] else { return false }
        if case .measure = chord.duration { return false }
        // A rest that carries anything (hidden, colored, a spanner, graces, markup, ...) is a wall: replacing it
        // would drop that. It is carried exactly as written and ends the run on both sides.
        return chord == Chord(duration: chord.duration, notes: [])
    }

    /// A note chord outside tuplets. A note that spans "the whole bar" by name is carried as written.
    func isNoteCandidate(_ index: Int) -> Bool {
        guard let chord = chord(at: index), !chord.notes.isEmpty, !isTupletMember[index] else { return false }
        if case .measure = chord.duration { return false }
        return true
    }

    // MARK: Spelling

    func spell(
        ticks: Int, at onset: Int, isRest: Bool, policy override: RhythmSpellingPolicy? = nil,
    ) -> [NoteDuration] {
        RhythmSpelling.durations(
            forTicks: ticks, startingAt: onset + pickupOffset, isRest: isRest,
            meterNumerator: facts.meterNumerator, meterDenominator: facts.meterDenominator,
            barTicks: facts.barTicks, isPickup: facts.isPickup, policy: override ?? policy, division: facts.division,
        )
    }

    func ticks(of duration: NoteDuration) -> Int {
        duration.resolved(in: Fraction(ticks: facts.barTicks, division: facts.division)).ticks(division: facts.division)
    }

    func totalTicks(_ range: ClosedRange<Int>) -> Int {
        range.reduce(0) { $0 + lengths[$1] }
    }

    // MARK: The span-level keepWritten rule (§3.2)

    /// A rest or note written as ONE element is kept as written when the splitter under `.allow` gives back exactly
    /// its own duration and under `.split` would not — a genuine crossing the author wrote. Anything else is spelled
    /// under `.split`, so the formatter never creates a crossing by merging.
    ///
    /// So is a note written as one dotted half beat across a weaker beat (`isWrittenDottedHalfBeat`), whatever the
    /// knobs say.
    func isKeptCrossing(at index: Int, isRest: Bool) -> Bool {
        if !isRest, !policy.readsLikeMuseScore, isWrittenDottedHalfBeat(at: index) { return true }
        let mode = isRest ? policy.beatCrossingRests : policy.midBarSyncopations
        guard mode == .keepWritten else { return false }
        var allowed = policy
        var split = policy
        if isRest {
            allowed.beatCrossingRests = .allow
            split.beatCrossingRests = .split
        } else {
            allowed.midBarSyncopations = .allow
            split.midBarSyncopations = .split
        }
        let own = lengths[index]
        let asAllowed = spell(ticks: own, at: onsets[index], isRest: isRest, policy: allowed)
        let asSplit = spell(ticks: own, at: onsets[index], isRest: isRest, policy: split)
        return isOwn(asAllowed, ticks: own) && !isOwn(asSplit, ticks: own)
    }

    /// A note a dotted half beat long (a dotted eighth in x/4) across exactly one weaker beat of simple time: a member
    /// of a 3+3+2 or 2+3+3 grouping, which the splitter would cut at the beat as a 16th-grid syncopation. The grouping
    /// is the author's phrasing, and it is recognised by the note's own shape rather than by its neighbours, so a rest,
    /// a tie or a pair of 16ths in place of the "2" changes nothing. Kept, never created: a tie that spells the same
    /// span is not merged into it.
    private func isWrittenDottedHalfBeat(at index: Int) -> Bool {
        guard RhythmMeter.isReadable(
            numerator: facts.meterNumerator, denominator: facts.meterDenominator, division: facts.division,
        ) else { return false }
        let meter = RhythmMeter(
            numerator: facts.meterNumerator, denominator: facts.meterDenominator, division: facts.division,
        )
        guard !meter.isCompound, lengths[index] * 4 == meter.dUnitTicks * 3 else { return false }
        let start = onsets[index] + pickupOffset
        let crossed = meter.strongestBeat(from: start, to: start + lengths[index], savingLast: false)
        return crossed.dUnitsCrossed == 1 && crossed.type == .simpleUnstressed
    }

    private func isOwn(_ durations: [NoteDuration], ticks own: Int) -> Bool {
        guard durations.count == 1 else { return false }
        let only = durations[0]
        if case .measure = only { return false }
        return ticks(of: only) == own
    }

    // MARK: Whether a span may be rewritten at all (§4.1, §5)

    /// The span lies inside the window, and no fermata or breath is the stream element right before or right after
    /// it (their hold is measured from the neighbouring chord).
    func mayRewrite(_ range: ClosedRange<Int>) -> Bool {
        let start = onsets[range.lowerBound]
        if let window = facts.window, start < window.lowerBound || start + totalTicks(range) > window.upperBound {
            return false
        }
        for neighbor in [range.lowerBound - 1, range.upperBound + 1] where elements.indices.contains(neighbor) {
            switch elements[neighbor] {
            case .fermata, .breath: return false
            default: continue
            }
        }
        return true
    }

    /// A chord in the span carries something whose SOUND depends on the chord's length, so splitting or merging
    /// would change what plays. Lyrics, slur begins, dynamics, chord symbols, color and visibility do not count.
    func isDurationSensitive(_ range: ClosedRange<Int>) -> Bool {
        for index in range {
            guard let chord = chord(at: index) else { continue }
            if tremoloFollowers.contains(index) || chord.tremolo != nil || chord.arpeggio != nil { return true }
            if !chord.graceNotesBefore.isEmpty || !chord.articulations.isEmpty || !chord.ornaments.isEmpty
                || !chord.chordLines.isEmpty { return true }
            // After-graces are timed against their chord's length, so any re-spelling could change the sound.
            if !chord.graceNotesAfter.isEmpty { return true }
            if chord.notes.contains(where: {
                $0.glissando != nil || $0.guitarBend != nil || $0.guitarBendBack || $0.legacyBend != nil
            }) { return true }
        }
        return false
    }

    // MARK: Absorbing a tie continuation (§4.2)

    /// How far the note span starting at `start` reaches. A preserved `<Beam>` marker between two chords does not
    /// end it (`isTransparentBeamMarker`); the span then includes the marker, which is dropped if the span is
    /// rewritten.
    func noteSpanEnd(from start: Int) -> Int {
        var end = start
        var next = start + 1
        while next < elements.count {
            if isTransparentBeamMarker(next) {
                next += 1
                continue
            }
            guard canAbsorb(next: next, into: end) else { break }
            end = next
            next += 1
        }
        return end
    }

    /// A `<Beam>` node MuseScore writes for a hand-set beam, kept verbatim in the stream before the chord its beam
    /// starts on (it carries that beam's stem positions). Folding that chord into a tied chain removes the chord, so
    /// the beam it started no longer exists: beams regroup from the new durations, and the marker goes with the chord
    /// rather than being handed to a piece it never described. One that hides its beam (`<visible>0</visible>`) still
    /// stops the merge — the hidden beam is a visible choice the chain would lose.
    func isTransparentBeamMarker(_ index: Int) -> Bool {
        guard case let .preserved(xml) = elements[index], xml.name == "Beam" else { return false }
        return xml.children.first(where: { $0.name == "visible" })?.text != "0"
    }

    /// The chord indices of `range`, in order — a note span can hold a transparent beam marker between its chords.
    func chordIndices(_ range: ClosedRange<Int>) -> [Int] {
        range.filter { chord(at: $0) != nil }
    }

    private func canAbsorb(next: Int, into previous: Int) -> Bool {
        guard isNoteCandidate(next), let a = chord(at: previous), let b = chord(at: next),
              a.graceNotesAfter.isEmpty, a.tremolo == nil,
              !tremoloFollowers.contains(previous), !tremoloFollowers.contains(next),
              !facts.protectedOnsets.contains(onsets[next]),
              a.notes.count == b.notes.count, isBare(b)
        else { return false }
        return zip(a.notes, b.notes).allSatisfy { first, second in
            first.tieForward != nil && second.tieBack != nil && first.pitch == second.pitch && first.tpc == second.tpc
        }
    }

    /// Nothing on the chord would be lost by folding it into the chain before it.
    private func isBare(_ chord: Chord) -> Bool {
        let bare = Chord(duration: chord.duration, notes: chord.notes)
        guard chord == bare else { return false }
        return chord.notes.allSatisfy { note in
            note == Note(
                pitch: note.pitch, tpc: note.tpc, accidental: note.accidental,
                accidentalBracket: note.accidentalBracket, accidentalRole: note.accidentalRole,
                tieForward: note.tieForward, tieBack: note.tieBack,
            )
        }
    }
}
