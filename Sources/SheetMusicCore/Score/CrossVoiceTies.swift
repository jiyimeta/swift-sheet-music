import SheetMusicFoundation

/// Ties whose two ends sit in different voices of one staff.
///
/// MuseScore ties a note to the note of the same pitch at the position the chord ends, in whichever voice of the
/// staff holds one, its own voice first (`searchTieNote`, `dom/utils.cpp`). Where voices part or merge — a note held
/// in voice 2 that voice 1 carries on in the next bar — the tie therefore crosses voices, and MuseScore writes the
/// voice step into the tie's `<location>` (`<voices>-1</voices>`). The model's tie is presence-only
/// (`Note.tieForward` / `Note.tieBack`), and everything that pairs the two ends walks one voice — `TiePlanner`,
/// `MidiRenderer.resolvingTiedPitches` and the MSCX reader's pairing — so such a tie read as two halves with no
/// partner and was dropped on import (`mscx.tie.unpairedSide`). This finds them by the rule MuseScore makes them
/// with, so each of those can accept a partner in another voice.
///
/// A forward end is linked only when its own voice has no tie landing on a note of its pitch at that position, and a
/// back end only when its own voice feeds it no tie of its pitch: a tie inside one voice — including one whose two
/// ends are spelled apart by a key change — stays that voice's own to pair. Grace chords are left to their voice too.
package enum CrossVoiceTies {
    /// One note of the staff: which measure, which voice in it, which element in the voice, which note in the chord.
    package struct End: Hashable, Sendable {
        package var measure: Int
        package var voice: Int
        package var element: Int
        package var note: Int

        package init(measure: Int, voice: Int, element: Int, note: Int) {
            self.measure = measure
            self.voice = voice
            self.element = element
            self.note = note
        }
    }

    /// A tie from a note carrying `tieForward` to a note in another voice carrying `tieBack`.
    package struct Link: Hashable, Sendable {
        package var from: End
        package var to: End
        /// Where the chord of each end starts within its own measure — what a writer needs to name the other end.
        package var fromOffset: Fraction
        package var toOffset: Fraction
    }

    /// Every cross-voice tie in one staff's `measures` whose forward end lies in `sourceMeasures` (all of them when
    /// nil). A caller asking about one note passes the measures it can be tied from, which keeps the walk to a bar or
    /// two of a long score.
    package static func links(in measures: [Measure], sourceMeasures: ClosedRange<Int>? = nil) -> [Link] {
        guard !measures.isEmpty else { return [] }
        let lower = max(sourceMeasures?.lowerBound ?? 0, 0)
        let upper = min(sourceMeasures?.upperBound ?? measures.count - 1, measures.count - 1)
        guard lower <= upper else { return [] }
        let sources = lower ... upper
        // A staff that never splits into voices — most of them — has nothing to find, and layout and playback ask
        // about every staff of the score.
        guard measures[sources].contains(where: { $0.voices.count > 1 })
            || measures.indices.contains(upper + 1) && measures[upper + 1].voices.count > 1
        else { return [] }
        // A tie from these bars lands in them or in the bar after; one fed from the bar before decides whether a
        // landing note is already taken by its own voice.
        let timeline = Timeline(
            measures: measures, window: max(lower - 1, 0) ... min(upper + 1, measures.count - 1),
        )

        var links: [Link] = []
        var claimed: Set<End> = []
        for measureIndex in sources {
            for (voiceIndex, voice) in measures[measureIndex].voices.enumerated() {
                for (elementIndex, element) in voice.elements.enumerated() {
                    guard case let .chord(chord) = element,
                          chord.notes.contains(where: { $0.tieForward != nil }),
                          let start = timeline.start(measure: measureIndex, voice: voiceIndex, element: elementIndex),
                          let target = timeline.endPosition(
                              measure: measureIndex, voice: voiceIndex, element: elementIndex,
                          )
                    else { continue }
                    let ownNext = timeline.chord(at: target, voice: voiceIndex)
                    for noteIndex in chord.notes.indices where chord.notes[noteIndex].tieForward != nil {
                        let pitch = chord.notes[noteIndex].pitch
                        let landsInOwnVoice = ownNext?.chord.notes.contains {
                            $0.tieBack != nil && $0.pitch == pitch
                        } ?? false
                        if landsInOwnVoice { continue }
                        let from = End(measure: measureIndex, voice: voiceIndex, element: elementIndex, note: noteIndex)
                        if let to = landing(
                            pitch: pitch, at: target, from: voiceIndex, timeline: timeline, claimed: claimed,
                        ) {
                            claimed.insert(to)
                            links.append(Link(from: from, to: to, fromOffset: start, toOffset: target.offset))
                        }
                    }
                }
            }
        }
        return links
    }

    /// The note in another voice that a forward tie of `pitch` from `voice` lands on at `position`: the first voice,
    /// in index order, holding a chord that starts exactly there with an unclaimed note of that pitch carrying
    /// `tieBack` that its own voice does not feed.
    private static func landing(
        pitch: Int, at position: Timeline.Position, from voice: Int, timeline: Timeline, claimed: Set<End>,
    ) -> End? {
        for otherVoice in timeline.voiceIndices(in: position.measure) where otherVoice != voice {
            guard let target = timeline.chord(at: position, voice: otherVoice) else { continue }
            let fedByOwnVoice = timeline.chord(endingAt: position, voice: otherVoice)?.chord.notes
                .contains { $0.tieForward != nil && $0.pitch == pitch } ?? false
            guard !fedByOwnVoice else { continue }
            for noteIndex in target.chord.notes.indices {
                let note = target.chord.notes[noteIndex]
                guard note.tieBack != nil, note.pitch == pitch else { continue }
                let end = End(measure: position.measure, voice: otherVoice, element: target.element, note: noteIndex)
                if !claimed.contains(end) { return end }
            }
        }
        return nil
    }

    /// Where each chord of the bars in `window` starts and ends, so a tie's landing position can be found in every
    /// voice. Bars outside it read as empty.
    private struct Timeline {
        struct Position: Hashable {
            var measure: Int
            var offset: Fraction
        }

        struct Located {
            var element: Int
            var chord: Chord
        }

        private let measures: [Measure]
        private let durations: [Fraction]
        /// Per measure and voice: chords with notes, keyed by where they start and where they end.
        private var starting: [[[Fraction: Located]]] = []
        private var ending: [[[Fraction: Located]]] = []
        private var spans: [[[Int: (start: Fraction, end: Fraction)]]] = []

        init(measures: [Measure], window: ClosedRange<Int>) {
            self.measures = measures
            durations = measures.effectiveMeasureDurations()
            for (measureIndex, measure) in measures.enumerated() {
                var startingByVoice: [[Fraction: Located]] = []
                var endingByVoice: [[Fraction: Located]] = []
                var spansByVoice: [[Int: (start: Fraction, end: Fraction)]] = []
                for voice in measure.voices {
                    guard window.contains(measureIndex) else {
                        startingByVoice.append([:])
                        endingByVoice.append([:])
                        spansByVoice.append([:])
                        continue
                    }
                    var offset = Fraction(numerator: 0, denominator: 1)
                    var startingHere: [Fraction: Located] = [:]
                    var endingHere: [Fraction: Located] = [:]
                    var spansHere: [Int: (start: Fraction, end: Fraction)] = [:]
                    for (elementIndex, element) in voice.elements.enumerated() {
                        guard case let .chord(chord) = element else { continue }
                        let end = offset + chord.duration.resolved(in: durations[measureIndex]).asFraction
                        if !chord.notes.isEmpty {
                            startingHere[offset] = Located(element: elementIndex, chord: chord)
                            endingHere[end] = Located(element: elementIndex, chord: chord)
                            spansHere[elementIndex] = (offset, end)
                        }
                        offset = end
                    }
                    startingByVoice.append(startingHere)
                    endingByVoice.append(endingHere)
                    spansByVoice.append(spansHere)
                }
                starting.append(startingByVoice)
                ending.append(endingByVoice)
                spans.append(spansByVoice)
            }
        }

        func voiceIndices(in measure: Int) -> Range<Int> {
            measures.indices.contains(measure) ? measures[measure].voices.indices : 0 ..< 0
        }

        /// Where a chord starts within its measure.
        func start(measure: Int, voice: Int, element: Int) -> Fraction? {
            spans[measure][voice][element]?.start
        }

        /// The position a chord's last tick ends at — the next bar's start when it fills its own.
        func endPosition(measure: Int, voice: Int, element: Int) -> Position? {
            guard let end = spans[measure][voice][element]?.end else { return nil }
            let length = durations[measure]
            if end.numerator * length.denominator >= length.numerator * end.denominator {
                return Position(measure: measure + 1, offset: end - length)
            }
            return Position(measure: measure, offset: end)
        }

        /// The chord with notes that starts at `position` in `voice`.
        func chord(at position: Position, voice: Int) -> Located? {
            guard starting.indices.contains(position.measure),
                  starting[position.measure].indices.contains(voice)
            else { return nil }
            return starting[position.measure][voice][position.offset]
        }

        /// The chord with notes in `voice` whose last tick ends at `position` — in the bar before, at the start of one.
        func chord(endingAt position: Position, voice: Int) -> Located? {
            if position.offset.numerator == 0, position.measure > 0 {
                let previous = position.measure - 1
                guard ending[previous].indices.contains(voice) else { return nil }
                return ending[previous][voice][durations[previous]]
            }
            guard ending.indices.contains(position.measure),
                  ending[position.measure].indices.contains(voice)
            else { return nil }
            return ending[position.measure][voice][position.offset]
        }
    }
}

extension CrossVoiceTies.End {
    package init(_ noteID: NoteID) {
        self.init(
            measure: noteID.measureIndex, voice: noteID.voiceIndex, element: noteID.elementIndex,
            note: noteID.noteIndexInChord,
        )
    }

    package init(_ location: VoiceElementID, note: Int) {
        self.init(
            measure: location.measureIndex, voice: location.voiceIndex, element: location.elementIndex, note: note,
        )
    }
}

extension NoteID {
    package init(_ end: CrossVoiceTies.End, staff: StaffAddress) {
        self.init(
            staff: staff, measureIndex: end.measure, voiceIndex: end.voice, elementIndex: end.element,
            noteIndexInChord: end.note,
        )
    }
}
