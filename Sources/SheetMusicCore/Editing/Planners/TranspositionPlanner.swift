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
    ///
    /// **A whole number of octaves leaves the key exactly where it was**, rather than being re-read through the
    /// window: C♯ major moved an octave is still C♯ major, not the D♭ major its five flats would otherwise win.
    static func key(_ concertKey: Int, transposedBy semitones: Int) -> Int {
        guard semitones % 12 != 0 else { return concertKey }
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
    ///
    /// `sourceKeys` is the score whose key signatures say what key each note was in BEFORE the move — `nil` for the
    /// chromatic rule, which needs no such thing. It is passed separately from `working` because the two differ
    /// for `TransposeScore`, which writes the new key signatures before it plans a single note.
    static func steps(
        at target: VoiceElementID, in working: Score, semitones: Int, sourceKeys: Score?,
        visited: inout Set<NoteID>,
    ) -> [any EditCommand] {
        var commands: [any EditCommand] = []
        if let grace = graceRetune(at: target, in: working, semitones: semitones, sourceKeys: sourceKeys) {
            commands.append(grace)
        }
        commands += RangeEditPlanner.unvisitedTieChains(of: target, in: working, visited: &visited)
            .flatMap { retune(chain: $0, in: working, semitones: semitones, sourceKeys: sourceKeys) }
        return commands
    }

    /// `SetNotePitch` for every member of one tie chain, all carrying the head's shifted pitch and tpc; `[]` when
    /// the shift would leave MIDI range.
    ///
    /// A tie chain is one sounding note written across several slots, so the whole chain moves together and the
    /// accidental is written on the head alone — the far side of a tie carries none. The key it is spelled from is
    /// the HEAD's, which is where the chain's pitch is written.
    static func retune(
        chain: [NoteID], in score: Score, semitones: Int, sourceKeys: Score?,
    ) -> [any EditCommand] {
        guard let head = chain.first, let note = score[head] else { return [] }
        let keySig = score.activeKey(at: head)
        guard let shifted = shifted(
            note, by: semitones, in: keySig, fromKey: sourceKeys?.activeKey(at: head),
        ) else { return [] }
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
        at target: VoiceElementID, in score: Score, semitones: Int, sourceKeys: Score?,
    ) -> (any EditCommand)? {
        guard case let .chord(chord)? = score[target],
              !chord.graceNotesBefore.isEmpty || !chord.graceNotesAfter.isEmpty
        else { return nil }
        let keySig = score.activeKey(staff: target.staff, measureIndex: target.measureIndex)
        let fromKey = sourceKeys?.activeKey(staff: target.staff, measureIndex: target.measureIndex)
        var moved = chord
        for index in chord.graceNotesBefore.indices {
            guard let notes = shifted(
                chord.graceNotesBefore[index].notes, by: semitones, in: keySig, fromKey: fromKey,
            ) else { return nil }
            moved.graceNotesBefore.updateValue(at: index) { $0.notes = notes }
        }
        for index in chord.graceNotesAfter.indices {
            guard let notes = shifted(
                chord.graceNotesAfter[index].notes, by: semitones, in: keySig, fromKey: fromKey,
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

    /// One note moved, `nil` when the result would leave MIDI 0…127. `keySig` is the key the moved note is READ
    /// under — what decides the accidental it is drawn with.
    ///
    /// Without `fromKey`, the chromatic rule `Note.shifted(bySemitones:in:)` applies one semitone at a time: what
    /// ↑ / ↓ does to a note, and what a range moved by a semitone count with no key in mind gets.
    ///
    /// With it, the note **keeps its place relative to the scale** (`respellInKey`). `fromKey` is the key the note
    /// was in before the move; moving the music moves that key to `key(fromKey, transposedBy:)`, and the note's
    /// tpc moves round the line of fifths by exactly as many fifths as the key did. A note that was the
    /// sixth degree lowered stays the sixth degree lowered: in B major a G♮ is ♭6, and moved down three semitones
    /// into A♭ major it is F♭ — not the E♮ that is simply the plainest name for its new pitch. That is what a
    /// musician transposing by hand writes, and it is how MuseScore spells a transposition by key.
    ///
    /// The fifths the key moves always agree with the semitones the pitch does, modulo an octave (`key(_:
    /// transposedBy:)` picks from the residue of `7 · semitones`), so the tpc and the pitch never disagree about the
    /// note. The one repair is past the double accidentals: a spelling beyond 𝄫 or 𝄪 — reachable only from a note
    /// already doubly altered — is read back by twelve fifths into the enharmonic that is.
    private static func shifted(
        _ note: Note, by semitones: Int, in keySig: Int, fromKey: Int?,
    ) -> Note? {
        guard let fromKey else { return note.shifted(bySemitones: semitones, in: keySig) }
        let pitch = note.pitch + semitones
        guard (0 ... 127).contains(pitch) else { return nil }
        var tpc = note.tpc + key(fromKey, transposedBy: semitones) - fromKey
        while tpc > maximumTpc {
            tpc -= 12
        }
        while tpc < minimumTpc {
            tpc += 12
        }
        var moved = note
        moved.pitch = pitch
        moved.tpc = tpc
        moved.accidental = PitchSpelling.displayedAccidental(forTpc: tpc, in: keySig)
        return moved
    }

    /// F𝄫 and B𝄪 — the two ends of the line of fifths a spelling can be written with.
    private static let minimumTpc = -1
    private static let maximumTpc = 33

    /// A whole chord's notes moved, or `nil` when any one of them cannot be. Identifiers survive: `mapValues` is
    /// the mutation this type's doc comment names transposition as the caller of, and a uniform shift is
    /// injective, so it never collides two pitches onto one and never drops a slot.
    private static func shifted(
        _ notes: ChordNotes, by semitones: Int, in keySig: Int, fromKey: Int?,
    ) -> ChordNotes? {
        var moved = notes
        var refused = false
        moved.mapValues { note in
            guard let next = shifted(note, by: semitones, in: keySig, fromKey: fromKey) else {
                refused = true
                return note
            }
            return next
        }
        return refused ? nil : moved
    }
}
