import SheetMusicFoundation

/// The notes of one measure in the order MuseScore's accidental state reads them, and what each tied-back one was
/// tied from — the walk `Score.suppressingRedundantAccidentals()` and `MeasureAccidentals` share.
///
/// MuseScore runs one `AccidentalState` per staff and measure (`ModifyDom::cmdUpdateNotes`): segment by segment, track
/// by track, and for each chord its grace notes before, then its own notes, then its grace notes after
/// (`Chord::cmdUpdateNotes`). Sorting by onset tick, voice, that phase, grace index and note index reproduces it.
enum MeasureAccidentalWalk {
    /// Where a note sits relative to its chord.
    enum Slot: Hashable {
        case graceBefore(Int)
        case main
        case graceAfter(Int)

        fileprivate var phase: (Int, Int) {
            switch self {
            case let .graceBefore(index): (0, index)
            case .main: (1, 0)
            case let .graceAfter(index): (2, index)
            }
        }
    }

    /// One note of a measure, addressed across every voice and carrying the onset tick that orders it.
    struct NoteRef: Hashable {
        let tick: Int
        let voice: Int
        let element: Int
        let slot: Slot
        let note: Int

        var isGrace: Bool {
            slot != .main
        }

        /// The address a tie start is keyed by — ties are read between a voice's own chords, never its graces.
        var mainAddress: MainAddress? {
            slot == .main ? MainAddress(voice: voice, element: element, note: note) : nil
        }
    }

    /// One note of a chord standing in a voice, within one measure.
    struct MainAddress: Hashable {
        let voice: Int
        let element: Int
        let note: Int
    }

    /// Every note in the measure, grace notes included, in MuseScore's order (see the type's comment).
    static func noteRefs(in measure: Measure, division: Int, measureDuration: Fraction) -> [NoteRef] {
        var refs: [NoteRef] = []
        for (voiceIndex, voice) in measure.voices.enumerated() {
            var tick = 0
            for (elementIndex, element) in voice.elements.enumerated() {
                if case let .chord(chord) = element {
                    func add(_ slot: Slot, _ count: Int) {
                        for noteIndex in 0 ..< count {
                            refs.append(NoteRef(
                                tick: tick, voice: voiceIndex, element: elementIndex, slot: slot, note: noteIndex,
                            ))
                        }
                    }
                    for (index, grace) in chord.graceNotesBefore.values.enumerated() {
                        add(.graceBefore(index), grace.notes.count)
                    }
                    add(.main, chord.notes.count)
                    for (index, grace) in chord.graceNotesAfter.values.enumerated() {
                        add(.graceAfter(index), grace.notes.count)
                    }
                }
                tick += element.tickCount(division: division, in: measureDuration) ?? 0
            }
        }
        return refs.sorted {
            if $0.tick != $1.tick { return $0.tick < $1.tick }
            if $0.voice != $1.voice { return $0.voice < $1.voice }
            if $0.slot.phase != $1.slot.phase { return $0.slot.phase < $1.slot.phase }
            return $0.note < $1.note
        }
    }

    /// The note `ref` names in `voices`, or nil when the address no longer holds one.
    static func note(at ref: NoteRef, in voices: [Voice]) -> Note? {
        guard voices.indices.contains(ref.voice),
              voices[ref.voice].elements.indices.contains(ref.element),
              case let .chord(chord) = voices[ref.voice].elements[ref.element]
        else { return nil }
        let notes: ChordNotes
        switch ref.slot {
        case .main: notes = chord.notes
        case let .graceBefore(index): notes = chord.graceNotesBefore[index].notes
        case let .graceAfter(index): notes = chord.graceNotesAfter[index].notes
        }
        return notes.indices.contains(ref.note) ? notes[ref.note] : nil
    }

    /// `body` applied to the note `ref` names in `voices`.
    static func updateNote(at ref: NoteRef, in voices: inout [Voice], _ body: (inout Note) -> Void) {
        guard case var .chord(chord) = voices[ref.voice].elements[ref.element] else { return }
        switch ref.slot {
        case .main:
            chord.notes.updateNote(at: ref.note, body)
        case let .graceBefore(index):
            chord.graceNotesBefore.updateValue(at: index) { $0.notes.updateNote(at: ref.note, body) }
        case let .graceAfter(index):
            chord.graceNotesAfter.updateValue(at: index) { $0.notes.updateNote(at: ref.note, body) }
        }
        voices[ref.voice].elements.updateValue(at: ref.element) { $0 = .chord(chord) }
    }

    // MARK: - Where a tie came from

    /// The tpc of the note each tied-back note of `measures[measureIndex]` is tied from — what MuseScore reads as
    /// `note->tieBack()->startNote()->tpc()` to tell a tie that keeps its spelling from one that changes it.
    ///
    /// Paired the way playback pairs them (`MidiRenderer.resolvingTiedPitches`): within a voice the previous chord's
    /// forward ties feed this chord's back ties in note order, a rest severs them, and signatures, clefs and the like
    /// sit between without breaking them; a tie into another voice comes from `crossVoice`
    /// (`CrossVoiceTies.links`). A tied-back note with no partner — a tie whose start is a grace note, or one left
    /// dangling — is absent, and callers say nothing new about it.
    static func tieStartTPCs(
        in measures: [Measure], measureIndex: Int, crossVoice: [CrossVoiceTies.Link],
    ) -> [MainAddress: Int] {
        func tpc(at end: CrossVoiceTies.End) -> Int? {
            guard measures.indices.contains(end.measure),
                  measures[end.measure].voices.indices.contains(end.voice),
                  measures[end.measure].voices[end.voice].elements.indices.contains(end.element),
                  case let .chord(chord) = measures[end.measure].voices[end.voice].elements[end.element],
                  chord.notes.indices.contains(end.note)
            else { return nil }
            return chord.notes[end.note].tpc
        }
        var starts: [MainAddress: Int] = [:]
        let forwardAcross = Set(crossVoice.map(\.from))
        let backAcross = Set(crossVoice.map(\.to))
        for link in crossVoice where link.to.measure == measureIndex {
            starts[MainAddress(voice: link.to.voice, element: link.to.element, note: link.to.note)] = tpc(at: link.from)
        }
        /// The forward ties a chord sends on, as the tpcs of their notes.
        func outgoing(_ chord: Chord, measure: Int, voice: Int, element: Int) -> [Int] {
            chord.notes.indices.compactMap { noteIndex in
                let end = CrossVoiceTies.End(measure: measure, voice: voice, element: element, note: noteIndex)
                return chord.notes[noteIndex].tieForward != nil && !forwardAcross.contains(end)
                    ? chord.notes[noteIndex].tpc : nil
            }
        }
        for (voiceIndex, voice) in measures[measureIndex].voices.enumerated() {
            var queue: [Int] = []
            let previous = measureIndex - 1
            if measures.indices.contains(previous), measures[previous].voices.indices.contains(voiceIndex) {
                let elements = measures[previous].voices[voiceIndex].elements
                if let last = elements.indices.last(where: {
                    if case .chord = elements[$0] { true } else { false }
                }), case let .chord(chord) = elements[last] {
                    queue = outgoing(chord, measure: previous, voice: voiceIndex, element: last)
                }
            }
            for (elementIndex, element) in voice.elements.enumerated() {
                guard case let .chord(chord) = element else { continue }
                for noteIndex in chord.notes.indices where chord.notes[noteIndex].tieBack != nil {
                    let end = CrossVoiceTies.End(
                        measure: measureIndex, voice: voiceIndex, element: elementIndex, note: noteIndex,
                    )
                    guard !backAcross.contains(end), !queue.isEmpty else { continue }
                    starts[MainAddress(voice: voiceIndex, element: elementIndex, note: noteIndex)] = queue.removeFirst()
                }
                queue = outgoing(chord, measure: measureIndex, voice: voiceIndex, element: elementIndex)
            }
        }
        return starts
    }
}
