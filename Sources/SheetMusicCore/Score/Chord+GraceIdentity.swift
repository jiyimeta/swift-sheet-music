import SheetMusicFoundation

extension Chord {
    /// A musical copy has new grace slots; their values and sounding order stay intact.
    mutating func clearGraceIDsForCopy() {
        graceNotesBefore = IdentifiedArray(graceNotesBefore.values)
        graceNotesAfter = IdentifiedArray(graceNotesAfter.values)
    }

    /// Assigned graces travel with their values, even when their parent chord takes a new identity.
    mutating func assignMissingGraceIDs(using ids: inout EIDAllocator) {
        graceNotesBefore.assignMissingIDs(using: &ids)
        graceNotesAfter.assignMissingIDs(using: &ids)
    }

    var hasUnassignedGraceIDs: Bool {
        graceNotesBefore.hasUnassignedIDs || graceNotesAfter.hasUnassignedIDs
    }
}

extension VoiceElement {
    func clearingGraceIDsForCopy() -> VoiceElement {
        guard case var .chord(chord) = self else { return self }
        chord.clearGraceIDsForCopy()
        return .chord(chord)
    }

    mutating func assignMissingGraceIDs(using ids: inout EIDAllocator) {
        guard case var .chord(chord) = self else { return }
        chord.assignMissingGraceIDs(using: &ids)
        self = .chord(chord)
    }

    var hasUnassignedGraceIDs: Bool {
        guard case let .chord(chord) = self else { return false }
        return chord.hasUnassignedGraceIDs
    }
}
