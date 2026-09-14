import SheetMusicFoundation

/// The post-edit pass that clears a tie left pointing at nothing — `MeasureAccidentals`' sibling, hung in the same
/// place (`ScoreEditSession.apply`) for the same reason.
///
/// A tie is a link between two notes, and only one of them is addressed when the other is removed. Delete a chord
/// and it becomes a rest; the note tied INTO it keeps its `tieForward`, and the note it was tied into keeps its
/// `tieBack`. MuseScore does not leave that state lying around — removing a chord clears both ends of every tie it
/// carried (`editing/addremoveelement.cpp:203-224` with `note.cpp:1348-1356`) — and the reason is audible rather
/// than cosmetic. `MidiRenderer` reads the two flags as MuseScore does:
///
/// - `tieBack != nil` SUPPRESSES the note-on, because the sound is already running from the head. Left dangling,
///   the surviving note is never struck — it simply does not play.
/// - `tieForward != nil` SUPPRESSES the note-off, because the sound continues into the next link. Left dangling,
///   nothing ever releases the note — it sounds until something else stops it.
///
/// Both are one bug with two faces, and which face a user sees depends only on which end of the tie they deleted.
///
/// ## Why a pass rather than a rule inside each command
///
/// Every command that can take a chord out of a voice can strand a tie: `DeleteVoiceElement`, `DeleteRange`, the
/// full-measure-rest collapse, `DeleteMeasure`, `RemoveNoteFromChord`, and every lengthening that swallows the
/// element after it (`SetChordDuration`, and so `SetDots`, `SetDurationInRange`, `SetDotsInRange`). Stating the
/// rule once against the score's final shape catches all of them, including the ones nobody has written yet —
/// the same argument that put the accidental repairs in one pass instead of in nine commands.
///
/// ## The scan is bounded
///
/// Measures whose bytes moved, widened by one bar on each side. A tie crosses at most one barline (`TiePlanner`
/// pairs a note with the ADJACENT timed element), so the partner of anything the edit touched is either in a
/// changed bar or immediately beside one. A surviving partner's own bytes do not move when its opposite number is
/// deleted, which is exactly why the diff alone is not enough.
enum DanglingTies {
    /// One `ReplaceVoiceElement` per chord holding a tie with no partner, addressed in `current` and read against
    /// it, so the commands are independent of each other and may be applied in any order.
    ///
    /// Empty in the overwhelming majority of edits, which is what keeps this affordable: the walk visits a handful
    /// of bars and allocates nothing unless it finds something to seal.
    static func sealCommands(in current: Score, changedFrom previous: Score) -> [any EditCommand] {
        var commands: [any EditCommand] = []
        for (partIndex, part) in current.parts.enumerated() {
            for (staffIndex, staff) in part.staves.enumerated() {
                let address = StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex)
                let before = previous[address]?.measures
                for measureIndex in scanned(staff.measures, changedFrom: before) {
                    commands.append(contentsOf: seals(
                        in: staff.measures[measureIndex], at: address, measureIndex: measureIndex, of: current,
                    ))
                }
            }
        }
        return commands
    }

    /// The measure indices worth looking at: every one whose contents differ from `before` (a measure `before` did
    /// not have at all counts), plus its immediate neighbours on either side.
    private static func scanned(_ measures: [Measure], changedFrom before: [Measure]?) -> [Int] {
        var scanned: Set<Int> = []
        for measureIndex in measures.indices {
            let wasThere = before?.indices.contains(measureIndex) == true
            guard !wasThere || before?[measureIndex] != measures[measureIndex] else { continue }
            for neighbor in (measureIndex - 1) ... (measureIndex + 1) where measures.indices.contains(neighbor) {
                scanned.insert(neighbor)
            }
        }
        return scanned.sorted()
    }

    /// The seals one measure needs — at most one command per chord, carrying every cleared flag that chord had.
    private static func seals(
        in measure: Measure, at address: StaffAddress, measureIndex: Int, of score: Score,
    ) -> [any EditCommand] {
        var commands: [any EditCommand] = []
        for (voiceIndex, voice) in measure.voices.enumerated() {
            for (elementIndex, element) in voice.elements.enumerated() {
                guard case let .chord(chord) = element, !chord.notes.isEmpty else { continue }
                let location = VoiceElementID(
                    staff: address, measureIndex: measureIndex, voiceIndex: voiceIndex, elementIndex: elementIndex,
                )
                guard let sealed = sealed(chord, at: location, in: score) else { continue }
                commands.append(ReplaceVoiceElement(at: location, with: .chord(sealed)))
            }
        }
        return commands
    }

    /// `chord` with every partnerless tie flag cleared, or `nil` when it has none — the common case, and the one
    /// that has to cost nothing.
    ///
    /// Partnership is asked of `TiePlanner`, which is also what the renderer's chain walk and every tie command
    /// agree on: the partner is a note of the ADJACENT timed element carrying the matching tie at the same rank.
    /// A note whose neighbour exists but carries no tie at that rank is dangling too — a chord that lost one of
    /// its notes shifts the ranks under the ties that outlived it.
    private static func sealed(_ chord: Chord, at location: VoiceElementID, in score: Score) -> Chord? {
        var sealed = chord
        var changed = false
        for noteIndex in chord.notes.indices {
            let noteID = NoteID(
                staff: location.staff, measureIndex: location.measureIndex, voiceIndex: location.voiceIndex,
                elementIndex: location.elementIndex, noteIndexInChord: noteIndex,
            )
            let note = chord.notes[noteIndex]
            let backIsDangling = note.tieBack != nil && TiePlanner.tiedNote(before: noteID, in: score) == nil
            let forwardIsDangling = note.tieForward != nil && TiePlanner.tiedNote(after: noteID, in: score) == nil
            guard backIsDangling || forwardIsDangling else { continue }
            sealed.notes.updateNote(at: noteIndex) {
                if backIsDangling { $0.tieBack = nil }
                if forwardIsDangling { $0.tieForward = nil }
            }
            changed = true
        }
        return changed ? sealed : nil
    }
}
