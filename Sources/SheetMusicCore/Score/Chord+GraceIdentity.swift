import SheetMusicFoundation

extension Chord {
    /// A musical copy has new grace slots; their values and sounding order stay intact.
    mutating func clearGraceIDsForCopy() {
        graceNotesBefore = IdentifiedArray(graceNotesBefore.values)
        graceNotesAfter = IdentifiedArray(graceNotesAfter.values)
    }

    /// Assigned notes and graces travel with their values, even when their parent chord takes a new identity.
    /// Covers this chord's own notes, each grace chord's notes, and both grace slot lists.
    mutating func assignMissingNestedIDs(using ids: inout EIDAllocator) {
        notes.assignMissingIDs(using: &ids)
        graceNotesBefore.assignMissingIDs(using: &ids)
        graceNotesAfter.assignMissingIDs(using: &ids)
        for index in graceNotesBefore.indices {
            graceNotesBefore.updateValue(at: index) { $0.notes.assignMissingIDs(using: &ids) }
        }
        for index in graceNotesAfter.indices {
            graceNotesAfter.updateValue(at: index) { $0.notes.assignMissingIDs(using: &ids) }
        }
    }

    var hasUnassignedNestedIDs: Bool {
        notes.hasUnassignedIDs || graceNotesBefore.hasUnassignedIDs || graceNotesAfter.hasUnassignedIDs
            || graceNotesBefore.contains { $0.notes.hasUnassignedIDs }
            || graceNotesAfter.contains { $0.notes.hasUnassignedIDs }
    }
}

extension VoiceElement {
    func clearingGraceIDsForCopy() -> VoiceElement {
        guard case var .chord(chord) = self else { return self }
        chord.clearGraceIDsForCopy()
        return .chord(chord)
    }

    mutating func assignMissingNestedIDs(using ids: inout EIDAllocator) {
        guard case var .chord(chord) = self else { return }
        chord.assignMissingNestedIDs(using: &ids)
        self = .chord(chord)
    }

    var hasUnassignedNestedIDs: Bool {
        guard case let .chord(chord) = self else { return false }
        return chord.hasUnassignedNestedIDs
    }
}
