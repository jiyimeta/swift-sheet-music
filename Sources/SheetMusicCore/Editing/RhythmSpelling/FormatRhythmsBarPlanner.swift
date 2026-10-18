/// The facts about one bar that decide how its voices are re-spelled.
struct FormatRhythmsBarFacts: Equatable {
    var meterNumerator: Int
    var meterDenominator: Int
    /// The bar's actual length in ticks.
    var barTicks: Int
    /// A pickup is right-aligned: every position is offset by (nominal meter length − `barTicks`).
    var isPickup: Bool
    var division: Int
    /// Bar-relative ticks a span must lie inside; `nil` is the whole bar. No pickup offset.
    var window: Range<Int>?
    /// Bar-relative onsets some slur ends on or some lyric melisma targets; no chord is folded into a chain there.
    var protectedOnsets: Set<Int>
}

/// Re-spells one bar-voice the way `RhythmSpelling` would, without changing a sounding note and without dropping a
/// marking. It finds the spans (a tie chain of bare continuations, a run of rests), decides which may be rewritten
/// (design §4.1–§4.2), spells them, and writes the voice back with the identities `DeleteRange` and `RebarPlanner`
/// use. Tuplet contents, untimed elements, location shifts and measure rests pass through untouched.
enum FormatRhythmsBarPlanner {
    /// The bar-voice re-spelled, or `nil` when no span changes.
    static func respell(
        _ voice: Voice, facts: FormatRhythmsBarFacts, policy: RhythmSpellingPolicy,
    ) -> (slots: [VoiceSlot], tupletSlots: [TupletSlot])? {
        var writer = FormatRhythmsBarWriter(
            voice: voice, context: FormatRhythmsBarContext(voice: voice, facts: facts, policy: policy),
        )
        writer.run()
        guard writer.changed else { return nil }
        return (writer.slots, writer.tupletSlots())
    }
}

/// Walks the bar-voice once, front to back, and accumulates the replacement slots.
private struct FormatRhythmsBarWriter {
    let voice: Voice
    let context: FormatRhythmsBarContext
    private(set) var slots: [VoiceSlot] = []
    private(set) var changed = false
    /// Where each element that was carried over landed, so a tuplet's endpoints can be re-pointed.
    private var newIndexForOldIndex: [Int: Int] = [:]

    init(voice: Voice, context: FormatRhythmsBarContext) {
        self.voice = voice
        self.context = context
    }

    mutating func run() {
        var index = 0
        while index < context.elements.count {
            if context.isRestCandidate(index) {
                var end = index
                while end + 1 < context.elements.count, context.isRestCandidate(end + 1) {
                    end += 1
                }
                writeRestRun(index ... end)
                index = end + 1
            } else if context.isNoteCandidate(index) {
                let end = context.noteSpanEnd(from: index)
                writeNoteSpan(index ... end)
                index = end + 1
            } else {
                carry(index)
                index += 1
            }
        }
    }

    /// The voice's tuplets with their endpoints re-pointed at the rewritten element list. Members are always carried
    /// over one-to-one, so every tuplet survives.
    func tupletSlots() -> [TupletSlot] {
        let spans = voice.tupletSpans
        return spans.indices.compactMap { index in
            guard let first = newIndexForOldIndex[spans[index].startIndex],
                  let last = newIndexForOldIndex[spans[index].endIndex]
            else { return nil }
            var tuplet = voice.tuplets[index]
            tuplet.first = .index(first)
            tuplet.last = .index(last)
            return TupletSlot(identity: .keep(voice.tuplets.eid(at: index)), tuplet: tuplet)
        }
    }

    // MARK: Carrying

    private mutating func carry(_ index: Int) {
        newIndexForOldIndex[index] = slots.count
        slots.append(VoiceSlot(identity: .keep(voice.elements.eid(at: index)), element: context.elements[index]))
    }

    private mutating func carry(_ range: ClosedRange<Int>) {
        for index in range {
            carry(index)
        }
    }

    // MARK: Rests

    /// A rest written as one element across a weaker beat is a wall: the rests on either side are separate runs.
    private mutating func writeRestRun(_ run: ClosedRange<Int>) {
        var open: Int?
        for index in run {
            if context.isKeptCrossing(at: index, isRest: true) {
                if let start = open { writeRestSpan(start ... index - 1) }
                open = nil
                carry(index)
            } else if open == nil {
                open = index
            } else if context.facts.protectedOnsets.contains(context.onsets[index]), let start = open {
                // A slur may end on a rest: no rest is folded into the one before it across that onset.
                writeRestSpan(start ... index - 1)
                open = index
            }
        }
        if let start = open { writeRestSpan(start ... run.upperBound) }
    }

    private mutating func writeRestSpan(_ range: ClosedRange<Int>) {
        guard context.mayRewrite(range) else {
            carry(range)
            return
        }
        let durations = context.spell(
            ticks: context.totalTicks(range), at: context.onsets[range.lowerBound], isRest: true,
        )
        // Nothing spelled: the span has no exact spelling, so it is carried as written.
        guard !durations.isEmpty else {
            carry(range)
            return
        }
        // Lengths that land where they already were are no re-spelling at all: the rests keep their identifiers and
        // their spelling (`DeleteRange`'s rule). A measure rest is always a change.
        let unchanged = durations.count == range.count
            && zip(durations, range).allSatisfy { duration, index in
                if case .measure = duration { return false }
                return context.ticks(of: duration) == context.lengths[index]
            }
        guard !unchanged else {
            carry(range)
            return
        }
        changed = true
        for duration in durations {
            slots.append(VoiceSlot(identity: .fresh, element: .rest(duration: duration)))
        }
    }

    // MARK: Notes

    private mutating func writeNoteSpan(_ range: ClosedRange<Int>) {
        guard context.mayRewrite(range), !context.isDurationSensitive(range),
              !(range.count == 1 && context.isKeptCrossing(at: range.lowerBound, isRest: false))
        else {
            carry(range)
            return
        }
        let durations = context.spell(
            ticks: context.totalTicks(range), at: context.onsets[range.lowerBound], isRest: false,
        )
        guard !durations.isEmpty else {
            carry(range)
            return
        }
        let chordIndices = context.chordIndices(range)
        let unchanged = durations.count == chordIndices.count
            && zip(durations, chordIndices).allSatisfy { context.ticks(of: $0) == context.lengths[$1] }
        guard !unchanged else {
            carry(range)
            return
        }
        changed = true
        let chords = range.compactMap { context.chord(at: $0) }
        newIndexForOldIndex[range.lowerBound] = slots.count
        let headID = voice.elements.eid(at: range.lowerBound)
        slots.append(contentsOf: Self.pieces(of: chords, headID: headID, durations: durations))
    }

    /// The span as a tied chain of `durations`. This is `RebarPlanner.pieces` for a span of several chords: the head
    /// is the first chord itself (identity, attachments, incoming tie); the span's LAST chord supplies the
    /// outgoing tie, which goes to the last piece (a span with after-graces is never rewritten); the pieces in between
    /// are bare copies of the head's notes. Every tie written is a complete pair.
    private static func pieces(of chords: [Chord], headID: EID, durations: [NoteDuration]) -> [VoiceSlot] {
        let head = chords[0]
        let last = chords[chords.count - 1]
        let count = durations.count
        func outgoingTie(_ noteIndex: Int, piece: Int) -> Int? {
            piece == count - 1 ? last.notes[noteIndex].tieForward : 1
        }

        var first = head
        first.duration = durations[0]
        for noteIndex in first.notes.indices {
            first.notes.updateNote(at: noteIndex) { $0.tieForward = outgoingTie(noteIndex, piece: 0) }
        }
        var result = [VoiceSlot(identity: .keep(headID), element: .chord(first))]

        for piece in 1 ..< count {
            var notes: [Note] = []
            for (noteIndex, source) in head.notes.enumerated() {
                var note = source
                note.fingerings = []
                note.symbols = []
                note.preservedMarkup = []
                DurationChangeAlgorithm.clearAccidental(&note)
                note.tieBack = 1
                note.tieForward = outgoingTie(noteIndex, piece: piece)
                notes.append(note)
            }
            var chord = Chord(duration: durations[piece], notes: ChordNotes(notes))
            chord.stemVisible = head.stemVisible
            chord.beamVisible = head.beamVisible
            chord.elementProperties.visible = head.elementProperties.visible
            chord.elementProperties.color = head.elementProperties.color
            result.append(VoiceSlot(identity: .fresh, element: .chord(chord)))
        }
        return result
    }
}
