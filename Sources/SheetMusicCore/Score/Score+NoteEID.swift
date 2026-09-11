import SheetMusicFoundation

/// Identity lookup for the top-level notes of a `Chord` — `Chord.notes`, not the notes nested in
/// `graceNotesBefore` / `graceNotesAfter`. Grace notes carry identifiers of their own (see
/// `GraceChord` / `ChordNotes`), but there is no `NoteID` that can address them, so a grace note's
/// identifier resolves to `nil` here rather than falling through to the chord that hosts it. See
/// `Score+EIDLookup.swift` for the equivalent pair over voice elements; this mirrors its shape.
///
/// A `NoteID` names a position, and edits move and vacate positions the same way they do for voice
/// elements: removing a chord, or a note ahead of it in the chord, shifts every later index, so a
/// positional selection must not be carried across an edit. To follow a note across an edit, resolve
/// `eid(at:)` before the edit and `notePosition(of:)` after it. Lookup by EID walks the score, linear
/// in the number of notes; callers resolving many identifiers should build their own map.
extension Score {
    /// The first match in part, staff, measure, voice, element, then note order, or `nil` for an
    /// invalid or absent identifier — including one that names a grace note rather than a top-level
    /// chord note. Identifiers are expected to be unique: `ScoreEditor`'s debug gate checks that
    /// after every edit. If they repeat anyway, the first match in this order wins.
    public func notePosition(of eid: EID) -> NoteID? {
        guard eid.isValid else { return nil }
        for (partIndex, part) in parts.enumerated() {
            for (staffIndex, staff) in part.staves.enumerated() {
                for (measureIndex, measure) in staff.measures.enumerated() {
                    for (voiceIndex, voice) in measure.voices.enumerated() {
                        for (elementIndex, element) in voice.elements.enumerated() {
                            guard case let .chord(chord) = element else { continue }
                            guard let noteIndex = chord.notes.index(of: eid) else { continue }
                            return NoteID(
                                staff: StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex),
                                measureIndex: measureIndex, voiceIndex: voiceIndex, elementIndex: elementIndex,
                                noteIndexInChord: noteIndex,
                            )
                        }
                    }
                }
            }
        }
        return nil
    }

    /// The slot's durable identifier, or `nil` if the position is out of range, does not name a
    /// chord, or is still unassigned.
    public func eid(at position: NoteID) -> EID? {
        guard let staff = self[position.staff],
              staff.measures.indices.contains(position.measureIndex)
        else { return nil }
        let voices = staff.measures[position.measureIndex].voices
        guard voices.indices.contains(position.voiceIndex) else { return nil }
        let elements = voices[position.voiceIndex].elements
        guard elements.indices.contains(position.elementIndex) else { return nil }
        guard case let .chord(chord) = elements[position.elementIndex] else { return nil }
        guard chord.notes.indices.contains(position.noteIndexInChord) else { return nil }
        let eid = chord.notes.eid(at: position.noteIndexInChord)
        return eid.isValid ? eid : nil
    }
}
