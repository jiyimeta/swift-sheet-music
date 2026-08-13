import SheetMusicFoundation

/// The two questions an editor asks about ties: what a note could be tied to, and what it already is tied to.
public enum TiePlanner {
    /// Finds the tie partner: the next chord (voice order, may cross the barline via `ElementNavigator`) containing a
    /// note at the same pitch. Returns that note's `NoteID`, or `nil` when there is no such note — a caller uses
    /// `nil` to decide that tying is unavailable from the source note.
    public static func tieTarget(for noteID: NoteID, in score: Score) -> NoteID? {
        guard let source = score[noteID] else { return nil }
        guard let nextLocation = ElementNavigator.nextTimedElement(after: VoiceElementID(noteID), in: score)
        else { return nil }
        guard case let .chord(nextChord)? = score[nextLocation], !nextChord.notes.isEmpty else { return nil }
        guard let matchIndex = nextChord.notes.firstIndex(where: { $0.pitch == source.pitch }) else { return nil }
        return NoteID(
            staff: nextLocation.staff,
            measureIndex: nextLocation.measureIndex,
            voiceIndex: nextLocation.voiceIndex,
            elementIndex: nextLocation.elementIndex,
            noteIndexInChord: matchIndex,
        )
    }

    /// Every notehead `noteID` is tied to, in voice order, including itself — walked in BOTH directions, so it comes
    /// out the same whichever member of the chain the caller happens to hold.
    ///
    /// A tie chain is one sounding note written across several slots, which is why pitch edits address it as a unit:
    /// retuning one member alone leaves two different pitches joined by what looks like a tie, something no reader
    /// can perform and no exporter can spell — and `MidiRenderer` carries the head's pitch through the chain, so the
    /// note goes on sounding at the old pitch while the score shows a curve into a new one. `tieTarget` above answers
    /// a different question — "is there something here to tie TO" — and matches on pitch; this one follows the ties
    /// that already exist.
    ///
    /// Untied notes come back as a chain of one, so callers need no special case for the common shape.
    public static func tieChain(containing noteID: NoteID, in score: Score) -> [NoteID] {
        guard score[noteID] != nil else { return [] }
        var chain = [noteID]
        var cursor = noteID
        // `contains` doubles as the cycle guard: a score whose ties loop (hand-edited, or half-decoded) would
        // otherwise spin here forever. Chains are a handful of notes long, so the linear scan costs nothing.
        while let previous = tiedNote(before: cursor, in: score), !chain.contains(previous) {
            chain.insert(previous, at: 0)
            cursor = previous
        }
        cursor = noteID
        while let next = tiedNote(after: cursor, in: score), !chain.contains(next) {
            chain.append(next)
            cursor = next
        }
        return chain
    }

    /// The note `noteID`'s `tieForward` lands on, or nil when it carries no tie forward.
    private static func tiedNote(after noteID: NoteID, in score: Score) -> NoteID? {
        guard case let .chord(chord)? = score[VoiceElementID(noteID)],
              chord.notes.indices.contains(noteID.noteIndexInChord),
              chord.notes[noteID.noteIndexInChord].tieForward != nil,
              let nextLocation = ElementNavigator.nextTimedElement(after: VoiceElementID(noteID), in: score),
              case let .chord(nextChord)? = score[nextLocation]
        else { return nil }
        let rank = chord.notes.prefix(noteID.noteIndexInChord).count { $0.tieForward != nil }
        guard let index = index(ofTie: rank, in: nextChord.notes, \.tieBack) else { return nil }
        return NoteID(
            staff: nextLocation.staff,
            measureIndex: nextLocation.measureIndex,
            voiceIndex: nextLocation.voiceIndex,
            elementIndex: nextLocation.elementIndex,
            noteIndexInChord: index,
        )
    }

    /// The mirror: the note whose `tieForward` lands on `noteID`, or nil when it carries no tie back.
    private static func tiedNote(before noteID: NoteID, in score: Score) -> NoteID? {
        guard case let .chord(chord)? = score[VoiceElementID(noteID)],
              chord.notes.indices.contains(noteID.noteIndexInChord),
              chord.notes[noteID.noteIndexInChord].tieBack != nil,
              let previousLocation = ElementNavigator.previousTimedElement(
                  before: VoiceElementID(noteID), in: score,
              ),
              case let .chord(previousChord)? = score[previousLocation]
        else { return nil }
        let rank = chord.notes.prefix(noteID.noteIndexInChord).count { $0.tieBack != nil }
        guard let index = index(ofTie: rank, in: previousChord.notes, \.tieForward) else { return nil }
        return NoteID(
            staff: previousLocation.staff,
            measureIndex: previousLocation.measureIndex,
            voiceIndex: previousLocation.voiceIndex,
            elementIndex: previousLocation.elementIndex,
            noteIndexInChord: index,
        )
    }

    /// Index of the `rank`-th note carrying a tie on `side`. Ties within a chord do not cross, so the n-th tie out of
    /// one chord pairs with the n-th tie into the next — the same rule `MidiRenderer` resolves tied pitches by.
    /// Matching on in-chord index instead would pair the wrong voices whenever only some of a chord's notes are tied.
    private static func index(ofTie rank: Int, in notes: ChordNotes, _ side: KeyPath<Note, Int?>) -> Int? {
        var remaining = rank
        for (index, note) in notes.enumerated() where note[keyPath: side] != nil {
            if remaining == 0 { return index }
            remaining -= 1
        }
        return nil
    }
}
