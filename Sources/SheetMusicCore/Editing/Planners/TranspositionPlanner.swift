import SheetMusicFoundation

/// The pitch arithmetic the two transposition commands share: how one tie chain moves, how a chord's grace notes
/// move with it, and where a key signature lands.
///
/// `TransposeRange` owns the range rules and `TransposeScore` the whole-score ones; neither owns the arithmetic,
/// because a range moved two semitones and a score moved two semitones have to spell their results identically —
/// otherwise the same music reads differently depending on how much of it the host had selected.
enum TranspositionPlanner {
    /// The concert key (fifths, −7…+7) that `concertKey` becomes when the music it governs moves `semitones`.
    ///
    /// Moving a key is moving it round the circle of fifths: one semitone up is seven fifths sharpwards, and the
    /// result is read back into the −7…+7 a signature can be written with by adding or subtracting twelve — the
    /// enharmonic wrap, twelve fifths being an octave's worth of nothing on the staff.
    ///
    /// Three pitch classes can be written two ways inside that window, and this takes the reading with FEWER
    /// accidentals: C up a semitone is D♭ (5 flats), not C♯ (7 sharps). The tritone is the one genuine tie — F♯
    /// and G♭ are six each — and it is broken by the DIRECTION of the move, up landing on the sharp side and down
    /// on the flat side, which is how a musician reads "up a tritone from C" as F♯. MuseScore asks the user
    /// instead, because its dialog transposes by a NAMED interval (an augmented fourth is F♯, a diminished fifth
    /// G♭) and the name settles it; a semitone count carries no such name, so the rule stands in for one.
    static func key(_ concertKey: Int, transposedBy semitones: Int) -> Int {
        let residue = (((concertKey + 7 * semitones) % 12) + 12) % 12
        let candidates = (-7 ... 7).filter { ((($0 % 12) + 12) % 12) == residue }
        guard var best = candidates.first else { return concertKey }
        for candidate in candidates.dropFirst() {
            if abs(candidate) < abs(best) {
                best = candidate
            } else if abs(candidate) == abs(best), semitones > 0 ? candidate > best : candidate < best {
                best = candidate
            }
        }
        return best
    }

    /// Every command one chord contributes to a transposition: its grace notes, then its unvisited tie chains.
    ///
    /// The grace-note replace comes FIRST because it copies the element whole. Run after the pitch writes it would
    /// carry the element as it stood before them and quietly undo the lot; run before, it copies whatever pitches
    /// the working score holds now and the `SetNotePitch`es land on top of it.
    static func steps(
        at target: VoiceElementID, in working: Score, semitones: Int, respellInKey: Bool,
        visited: inout Set<NoteID>,
    ) -> [any EditCommand] {
        var commands: [any EditCommand] = []
        if let grace = graceRetune(at: target, in: working, semitones: semitones, respellInKey: respellInKey) {
            commands.append(grace)
        }
        commands += RangeEditPlanner.unvisitedTieChains(of: target, in: working, visited: &visited)
            .flatMap { retune(chain: $0, in: working, semitones: semitones, respellInKey: respellInKey) }
        return commands
    }

    /// `SetNotePitch` for every member of one tie chain, all carrying the head's shifted pitch and tpc; `[]` when
    /// the shift would leave MIDI range.
    ///
    /// A tie chain is one sounding note written across several slots, so the whole chain moves together and the
    /// accidental is written on the head alone — the far side of a tie carries none.
    static func retune(
        chain: [NoteID], in score: Score, semitones: Int, respellInKey: Bool,
    ) -> [any EditCommand] {
        guard let head = chain.first, let note = score[head] else { return [] }
        let keySig = score.activeKey(at: head)
        guard let shifted = shifted(note, by: semitones, in: keySig, respellInKey: respellInKey) else { return [] }
        return chain.map { member in
            SetNotePitch(
                at: member, pitch: shifted.pitch, tpc: shifted.tpc,
                accidental: member == head ? shifted.accidental : nil,
            )
        }
    }

    /// The chord at `target` with its grace notes moved, or `nil` when it carries none — or when one of them
    /// cannot move without leaving MIDI range, in which case the ornament stays whole rather than half-transposed.
    ///
    /// Grace notes are the one pitched thing in the model a `NoteID` cannot address: `Chord.graceNotesBefore` and
    /// `graceNotesAfter` hold whole `GraceChord`s rather than notes of the parent chord, so `SetNotePitch` cannot
    /// reach them and an ornament would otherwise keep sounding in the key the music just left. The write is a
    /// whole-element replace at `.same` identity — every slot identifier survives (the chord's, its notes', its
    /// grace chords') and only the pitches and their spellings differ.
    ///
    /// Read from the WORKING score rather than the score the plan started from, so a chord whose main notes an
    /// earlier tie chain already moved is copied forward with those pitches instead of the ones it opened with.
    static func graceRetune(
        at target: VoiceElementID, in score: Score, semitones: Int, respellInKey: Bool,
    ) -> (any EditCommand)? {
        guard case let .chord(chord)? = score[target],
              !chord.graceNotesBefore.isEmpty || !chord.graceNotesAfter.isEmpty
        else { return nil }
        let keySig = score.activeKey(staff: target.staff, measureIndex: target.measureIndex)
        var moved = chord
        for index in chord.graceNotesBefore.indices {
            guard let notes = shifted(
                chord.graceNotesBefore[index].notes, by: semitones, in: keySig, respellInKey: respellInKey,
            ) else { return nil }
            moved.graceNotesBefore.updateValue(at: index) { $0.notes = notes }
        }
        for index in chord.graceNotesAfter.indices {
            guard let notes = shifted(
                chord.graceNotesAfter[index].notes, by: semitones, in: keySig, respellInKey: respellInKey,
            ) else { return nil }
            moved.graceNotesAfter.updateValue(at: index) { $0.notes = notes }
        }
        guard moved != chord else { return nil }
        return ReplaceVoiceElement(at: target, with: .chord(moved))
    }

    /// Whether every note of the chord at `target` — grace notes included — can move `semitones` and stay inside
    /// MIDI 0…127. What `TransposeScore` checks before it plans anything, so a whole-score move is all or nothing.
    static func canMove(_ target: VoiceElementID, in score: Score, semitones: Int) -> Bool {
        guard case let .chord(chord)? = score[target] else { return true }
        let keySig = score.activeKey(staff: target.staff, measureIndex: target.measureIndex)
        let graceNotes = (chord.graceNotesBefore.values + chord.graceNotesAfter.values).flatMap(\.notes.values)
        return (chord.notes.values + graceNotes).allSatisfy {
            $0.shifted(bySemitones: semitones, in: keySig) != nil
        }
    }

    /// One note moved, spelled by the chromatic rule `Note.shifted(bySemitones:in:)` applies one semitone at a
    /// time, or — with `respellInKey` — re-spelled to the simplest reading in `keySig`. `nil` when the result
    /// would leave MIDI 0…127.
    private static func shifted(
        _ note: Note, by semitones: Int, in keySig: Int, respellInKey: Bool,
    ) -> Note? {
        guard var shifted = note.shifted(bySemitones: semitones, in: keySig) else { return nil }
        if respellInKey {
            shifted.tpc = PitchSpelling.tpc(forPitch: shifted.pitch, keySig: keySig, mode: .simplest)
            shifted.accidental = PitchSpelling.displayedAccidental(forTpc: shifted.tpc, in: keySig)
        }
        return shifted
    }

    /// A whole chord's notes moved, or `nil` when any one of them cannot be. Identifiers survive: `mapValues` is
    /// the mutation this type's doc comment names transposition as the caller of, and a uniform shift is
    /// injective, so it never collides two pitches onto one and never drops a slot.
    private static func shifted(
        _ notes: ChordNotes, by semitones: Int, in keySig: Int, respellInKey: Bool,
    ) -> ChordNotes? {
        var moved = notes
        var refused = false
        moved.mapValues { note in
            guard let next = shifted(note, by: semitones, in: keySig, respellInKey: respellInKey) else {
                refused = true
                return note
            }
            return next
        }
        return refused ? nil : moved
    }
}
