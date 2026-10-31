import SheetMusicFoundation

/// Ties of one part whose far end is neither the next chord of their own voice nor (`CrossVoiceTies`) a chord of
/// another voice of their staff starting where they end: a tie into another staff of the part, and a tie that passes
/// over chords or rests to land on a later one.
///
/// MuseScore looks for a tie's partner across every track of the part, not only the staff's own
/// (`searchTieNote`, `dom/utils.cpp`), because a chord moved to the other staff of a piano (`<staffMove>`) still
/// belongs to its home staff's track. Its reader then pairs the two halves by `<location>`, whatever the distance
/// (`ConnectorInfoReader`), so files carry ties written as `<staves>±1</staves>` — a note held from one hand into the
/// other, or a broken chord whose moved notes each tie into the chord they sustain into (MuseScore's own
/// `vtest/scores/tie-4.mscz` and `tie-18.mscz`) — and ties that skip the chords in between, such as the ones
/// MuseScore 3.02 wrote over a hidden rest into the next bar. The model's tie is presence-only (`Note.tieForward` /
/// `Note.tieBack`), and everything that pairs the ends walks one staff, so these read as two halves with no partner
/// and were dropped on import (`mscx.tie.unpairedSide`).
///
/// This finds them by a rule every consumer shares, after the voice's own pairing and `CrossVoiceTies` have had their
/// say. A forward end takes part only when its own voice has no tie of its pitch landing where its chord ends (on the
/// next chord or a grace beside it) and it is not a cross-voice tie; a back end only when its own voice feeds it no tie
/// of its pitch and it is not one either. Such a forward end is linked, first, to a note of its pitch carrying
/// `tieBack` in a chord of another staff of the part starting where its chord ends; failing that, to one in the
/// earliest chord of any staff of the part starting later, no later than the bar after the one its chord ends in —
/// unless a chord sounding that pitch starts on the way.
package enum DetachedTies {
    /// One note of the part: which staff of it, then the note's place in that staff.
    package struct End: Hashable, Sendable {
        package var staff: Int
        package var measure: Int
        package var voice: Int
        package var element: Int
        package var note: Int

        package init(staff: Int, measure: Int, voice: Int, element: Int, note: Int) {
            self.staff = staff
            self.measure = measure
            self.voice = voice
            self.element = element
            self.note = note
        }

        /// The same note, addressed within its own staff.
        package var inStaff: CrossVoiceTies.End {
            CrossVoiceTies.End(measure: measure, voice: voice, element: element, note: note)
        }
    }

    /// A tie from a note carrying `tieForward` to a note carrying `tieBack` that the voice-level pairing cannot reach.
    package struct Link: Hashable, Sendable {
        package var from: End
        package var to: End
        /// Where the chord of each end starts within its own measure — what a writer needs to name the other end.
        package var fromOffset: Fraction
        package var toOffset: Fraction
    }

    /// Every detached tie of the part whose staves hold `staves`, with its forward end in `sourceMeasures` (all
    /// measures when nil).
    package static func links(in staves: [[Measure]], sourceMeasures: ClosedRange<Int>? = nil) -> [Link] {
        let measureCount = staves.map(\.count).max() ?? 0
        guard measureCount > 0 else { return [] }
        let lower = max(sourceMeasures?.lowerBound ?? 0, 0)
        let upper = min(sourceMeasures?.upperBound ?? measureCount - 1, measureCount - 1)
        guard lower <= upper,
              staves.contains(where: { hasForwardTie(in: $0, measures: lower ... upper) })
        else { return [] }
        // A tie from these bars ends in them or the bar after, and may land as late as the bar after that; one fed from
        // the bar before decides whether a landing note is already taken by its own voice.
        let window = max(lower - 1, 0) ... min(upper + 2, measureCount - 1)
        let timelines = staves.enumerated().map { Timeline(measures: $1, window: window, staff: $0) }
        // Nearly every tie lands in its own voice, so the cross-voice links and the part-wide index are worked out
        // only once some forward end does not.
        var found = candidates(sources: lower ... upper, timelines: timelines)
        guard !found.isEmpty else { return [] }
        let crossVoice = staves.map { measures -> (forward: Set<CrossVoiceTies.End>, back: Set<CrossVoiceTies.End>) in
            let links = measures.isEmpty ? [] : CrossVoiceTies.links(in: measures, sourceMeasures: window)
            return (Set(links.map(\.from)), Set(links.map(\.to)))
        }
        found.removeAll { crossVoice[$0.end.staff].forward.contains($0.end.inStaff) }
        guard !found.isEmpty else { return [] }
        var search = Search(timelines: timelines, crossVoice: crossVoice)
        return found.compactMap { search.link($0) }
    }

    /// The detached ties of `part`.
    package static func links(in part: Part, sourceMeasures: ClosedRange<Int>? = nil) -> [Link] {
        links(in: part.staves.map(\.measures), sourceMeasures: sourceMeasures)
    }

    /// The ends of a part's detached ties that sit on one of its staves, as that staff's walks need them: the forward
    /// ends to leave out of their voice's pairing, and each back end with the tpc of the note its tie comes from — what
    /// MuseScore reads as `note->tieBack()->startNote()->tpc()`.
    package struct StaffEnds: Sendable {
        package var forward: Set<CrossVoiceTies.End> = []
        package var back: Set<CrossVoiceTies.End> = []
        package var backStartTPCs: [CrossVoiceTies.End: Int] = [:]

        package init() {}

        /// The ends of `links` on staff `staff` of the part whose staves hold `staves`.
        package init(staff: Int, links: [Link], staves: [[Measure]]) {
            for link in links {
                if link.from.staff == staff { forward.insert(link.from.inStaff) }
                guard link.to.staff == staff else { continue }
                back.insert(link.to.inStaff)
                let from = link.from
                guard staves.indices.contains(from.staff), staves[from.staff].indices.contains(from.measure),
                      staves[from.staff][from.measure].voices.indices.contains(from.voice),
                      staves[from.staff][from.measure].voices[from.voice].elements.indices.contains(from.element),
                      case let .chord(chord) = staves[from.staff][from.measure].voices[from.voice]
                          .elements[from.element],
                          chord.notes.indices.contains(from.note)
                else { continue }
                backStartTPCs[link.to.inStaff] = chord.notes[from.note].tpc
            }
        }
    }

    /// The notes of each grace chord of one of `chord`'s runs.
    private static func graceRun(_ chord: Chord, _ run: KeyPath<Chord, IdentifiedArray<GraceChord>>) -> [ChordNotes] {
        chord[keyPath: run].values.map(\.notes)
    }

    private static func hasForwardTie(in measures: [Measure], measures range: ClosedRange<Int>) -> Bool {
        for measureIndex in range where measures.indices.contains(measureIndex) {
            for voice in measures[measureIndex].voices {
                for element in voice.elements {
                    if case let .chord(chord) = element, chord.notes.contains(where: { $0.tieForward != nil }) {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// A forward end looking for a partner outside its voice.
    private struct Candidate {
        var end: End
        var pitch: Int
        var start: Fraction
        var target: Position
    }

    /// The forward ends in `sources` their own voice does not pair, in the order their chords end — the earliest to end
    /// chooses first. The caller takes out the ones `CrossVoiceTies` pairs.
    private static func candidates(sources: ClosedRange<Int>, timelines: [Timeline]) -> [Candidate] {
        var found: [Candidate] = []
        for timeline in timelines {
            for measureIndex in sources {
                for voiceIndex in 0 ..< timeline.voiceCount(measure: measureIndex) {
                    for located in timeline.chords(measure: measureIndex, voice: voiceIndex)
                        where located.chord.notes.contains(where: { $0.tieForward != nil })
                    {
                        found += candidates(of: located, in: timeline)
                    }
                }
            }
        }
        return found.enumerated().sorted { lhs, rhs in
            lhs.element.target != rhs.element.target
                ? lhs.element.target < rhs.element.target : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The forward ends of `chord` its own voice does not take — on the next chord, on a grace before it, or on a grace
    /// after `chord` itself, where MuseScore looks first.
    private static func candidates(of chord: Timeline.Located, in timeline: Timeline) -> [Candidate] {
        let target = timeline.endPosition(of: chord)
        let ownNext = timeline.chord(at: target, voice: chord.voice)
        let landings = (ownNext.map { [$0.chord.notes] + graceRun($0.chord, \.graceNotesBefore) } ?? [])
            + graceRun(chord.chord, \.graceNotesAfter)
        return chord.chord.notes.indices.compactMap { noteIndex in
            let note = chord.chord.notes[noteIndex]
            guard note.tieForward != nil,
                  !landings.contains(where: { $0.contains { $0.tieBack != nil && $0.pitch == note.pitch } })
            else { return nil }
            return Candidate(
                end: End(
                    staff: chord.staff, measure: chord.position.measure, voice: chord.voice, element: chord.element,
                    note: noteIndex,
                ),
                pitch: note.pitch, start: chord.position.offset, target: target,
            )
        }
    }

    /// The part's chords, and the back ends already taken.
    private struct Search {
        let timelines: [Timeline]
        let crossVoice: [(forward: Set<CrossVoiceTies.End>, back: Set<CrossVoiceTies.End>)]
        /// Every chord with notes of the part in the window, in time order, then staff, then voice.
        let all: [Timeline.Located]
        var claimed: Set<End> = []

        init(timelines: [Timeline], crossVoice: [(forward: Set<CrossVoiceTies.End>, back: Set<CrossVoiceTies.End>)]) {
            self.timelines = timelines
            self.crossVoice = crossVoice
            all = timelines.flatMap(\.located).sorted { lhs, rhs in
                if lhs.position != rhs.position { return lhs.position < rhs.position }
                if lhs.staff != rhs.staff { return lhs.staff < rhs.staff }
                return lhs.voice < rhs.voice
            }
        }

        /// Link `candidate` to its partner in another staff where its chord ends, else to the first later one.
        mutating func link(_ candidate: Candidate) -> Link? {
            // Where the chord ends: another staff only. Its own staff was the voice's and `CrossVoiceTies`' to pair.
            let atTarget = chords(at: candidate.target)
            if let to = firstPartner(of: candidate, in: atTarget.filter { $0.staff != candidate.end.staff }) {
                return claim(to, for: candidate)
            }
            // A chord sounding the pitch where the tie ends, tied or not, is what the tie would have to pass through.
            if atTarget.contains(where: { $0.chord.notes.contains { $0.pitch == candidate.pitch } }) { return nil }
            var index = firstIndex { candidate.target < $0.position }
            while index < all.count, all[index].position.measure <= candidate.target.measure + 1 {
                let position = all[index].position
                let group = chords(at: position)
                // The candidate's own staff first: a tie skipping chords stays on its staff when it can.
                let ordered = group.filter { $0.staff == candidate.end.staff } + group.filter {
                    $0.staff != candidate.end.staff
                }
                if let to = firstPartner(of: candidate, in: ordered) {
                    return claim(to, for: candidate)
                }
                if group.contains(where: { $0.chord.notes.contains { $0.pitch == candidate.pitch } }) { return nil }
                index += group.count
            }
            return nil
        }

        private mutating func claim(_ to: (end: End, offset: Fraction), for candidate: Candidate) -> Link {
            claimed.insert(to.end)
            return Link(from: candidate.end, to: to.end, fromOffset: candidate.start, toOffset: to.offset)
        }

        private func chords(at position: Position) -> ArraySlice<Timeline.Located> {
            let first = firstIndex { !($0.position < position) }
            var last = first
            while last < all.count, all[last].position == position {
                last += 1
            }
            return all[first ..< last]
        }

        /// The index of the first chord of `all` that `isPast` holds for — `isPast` being false up to some point in
        /// time order and true from there on.
        private func firstIndex(where isPast: (Timeline.Located) -> Bool) -> Int {
            var low = 0
            var high = all.count
            while low < high {
                let middle = (low + high) / 2
                if isPast(all[middle]) { high = middle } else { low = middle + 1 }
            }
            return low
        }

        /// The first note of `candidate`'s pitch carrying `tieBack` in `group` that is free to take it.
        private func firstPartner<C: Collection>(
            of candidate: Candidate, in group: C,
        ) -> (end: End, offset: Fraction)? where C.Element == Timeline.Located {
            for located in group {
                guard let noteIndex = located.chord.notes.firstIndex(where: {
                    $0.tieBack != nil && $0.pitch == candidate.pitch
                }) else { continue }
                let end = End(
                    staff: located.staff, measure: located.position.measure, voice: located.voice,
                    element: located.element, note: noteIndex,
                )
                guard !claimed.contains(end), !crossVoice[located.staff].back.contains(end.inStaff) else { continue }
                // A back end its own voice feeds at that pitch is the voice's to pair: from the chord before, a grace
                // after that chord, or a grace before its own.
                let previous = timelines[located.staff].chord(endingAt: located.position, voice: located.voice)?.chord
                let feeders = (previous.map { [$0.notes] + graceRun($0, \.graceNotesAfter) } ?? [])
                    + graceRun(located.chord, \.graceNotesBefore)
                if feeders.contains(where: { $0.contains { $0.tieForward != nil && $0.pitch == candidate.pitch } }) {
                    continue
                }
                return (end, located.position.offset)
            }
            return nil
        }
    }

    /// A point in one staff's time: a measure and an offset within it.
    private struct Position: Hashable, Comparable {
        var measure: Int
        var offset: Fraction

        static func < (lhs: Position, rhs: Position) -> Bool {
            if lhs.measure != rhs.measure { return lhs.measure < rhs.measure }
            return lhs.offset.numerator * rhs.offset.denominator < rhs.offset.numerator * lhs.offset.denominator
        }
    }

    /// Where each chord with notes of one staff starts and ends, over the bars of a window. Bars outside it read as
    /// empty. Built for every staff of a part whenever a tie is looked up, so it is plain arrays — the chords of each
    /// voice of each bar in element order, which is time order — rather than lookup tables.
    private struct Timeline {
        struct Located {
            var staff: Int
            var voice: Int
            var element: Int
            var position: Position
            /// Where the chord's last tick ends within its measure (past the bar's length when it overfills it).
            var end: Fraction
            var chord: Chord
        }

        private let durations: [Fraction]
        private let window: ClosedRange<Int>
        /// Measure (counted from the window's first) → voice → its chords with notes.
        private var byMeasure: [[[Located]]] = []

        init(measures: [Measure], window: ClosedRange<Int>, staff: Int) {
            durations = measures.effectiveMeasureDurations()
            self.window = window
            for measureIndex in window {
                guard measures.indices.contains(measureIndex) else {
                    byMeasure.append([])
                    continue
                }
                byMeasure.append(measures[measureIndex].voices.enumerated().map { voiceIndex, voice in
                    var offset = Fraction(numerator: 0, denominator: 1)
                    var chords: [Located] = []
                    for (elementIndex, element) in voice.elements.enumerated() {
                        guard case let .chord(chord) = element else { continue }
                        let end = offset + chord.duration.resolved(in: durations[measureIndex]).asFraction
                        if !chord.notes.isEmpty {
                            chords.append(Located(
                                staff: staff, voice: voiceIndex, element: elementIndex,
                                position: Position(measure: measureIndex, offset: offset), end: end, chord: chord,
                            ))
                        }
                        offset = end
                    }
                    return chords
                })
            }
        }

        /// How many voices `measure` has; none outside the window.
        func voiceCount(measure: Int) -> Int {
            window.contains(measure) ? byMeasure[measure - window.lowerBound].count : 0
        }

        /// The chords with notes of `voice` in `measure`, in time order; empty outside the window.
        func chords(measure: Int, voice: Int) -> [Located] {
            guard window.contains(measure) else { return [] }
            let voices = byMeasure[measure - window.lowerBound]
            return voices.indices.contains(voice) ? voices[voice] : []
        }

        /// Every chord with notes in the window.
        var located: [Located] {
            byMeasure.flatMap { $0.flatMap(\.self) }
        }

        /// The position a chord's last tick ends at — the next bar's start when it fills its own.
        func endPosition(of chord: Located) -> Position {
            let length = durations[chord.position.measure]
            if chord.end.numerator * length.denominator >= length.numerator * chord.end.denominator {
                return Position(measure: chord.position.measure + 1, offset: chord.end - length)
            }
            return Position(measure: chord.position.measure, offset: chord.end)
        }

        /// The chord with notes that starts at `position` in `voice`.
        func chord(at position: Position, voice: Int) -> Located? {
            chords(measure: position.measure, voice: voice).first { $0.position.offset == position.offset }
        }

        /// The chord with notes in `voice` whose last tick ends at `position` — in the bar before, at the start of one.
        func chord(endingAt position: Position, voice: Int) -> Located? {
            if position.offset.numerator == 0, position.measure > 0 {
                let previous = position.measure - 1
                guard durations.indices.contains(previous) else { return nil }
                return chords(measure: previous, voice: voice).last { $0.end == durations[previous] }
            }
            return chords(measure: position.measure, voice: voice).first { $0.end == position.offset }
        }
    }
}

extension DetachedTies.End {
    package init(_ noteID: NoteID) {
        self.init(
            staff: noteID.staff.staffIndexInPart, measure: noteID.measureIndex, voice: noteID.voiceIndex,
            element: noteID.elementIndex, note: noteID.noteIndexInChord,
        )
    }
}

extension NoteID {
    package init(_ end: DetachedTies.End, part: Int) {
        self.init(
            staff: StaffAddress(partIndex: part, staffIndexInPart: end.staff), measureIndex: end.measure,
            voiceIndex: end.voice, elementIndex: end.element, noteIndexInChord: end.note,
        )
    }
}
