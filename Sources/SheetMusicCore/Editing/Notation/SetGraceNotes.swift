import SheetMusicFoundation

/// Replace both of a chord's grace lists in one undo step — the write behind a host's "add acciaccatura", which
/// sends the list it wants rather than an insertion.
///
/// Replace-the-list, not add-one, for the reason `SetJumps` / `SetMarkers` are plural: a chord legitimately holds
/// several graces, and a wholesale replacement is the only semantics whose inverse is bit-perfect (it is this same
/// command carrying the pre-image). Two empty lists clear both; there is no separate remove.
///
/// Order is the caller's. `graceNotesBefore` is stored left-to-right as MSCX writes it and `graceNotesAfter` as
/// `Chord::graceNotesAfter()` yields it; MuseScore inserts a new grace at `Chord::graceIndex()`
/// (`dom/chord.cpp:688-695`), so where a grace goes in the row is a host decision and this command does not sort.
///
/// It does NOT check that every member of `before` has `graceType.isAfter == false`, or the converse for `after`.
/// `GraceType.isAfter` is the DECODER's routing rule (`GraceType.swift:20-25`); the encoder writes each list back
/// with whatever tags its members carry, so a mismatched pair round-trips consistently. Enforcing the pairing
/// would make a legal-if-odd file un-editable, which is a worse failure than engraving what it says.
///
/// > Note: This command is sugar over `ReplaceVoiceElement`. See `docs/edit-commands.md`.
public struct SetGraceNotes: EditCommand {
    public let location: VoiceElementID
    public let before: [GraceChord]
    public let after: [GraceChord]

    public init(at location: VoiceElementID, before: [GraceChord], after: [GraceChord]) {
        self.location = location
        self.before = before
        self.after = after
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    /// The chord's two grace lists, or `nil` when `location` names no chord — what the planner compares against.
    static func current(at location: VoiceElementID, in score: Score) -> (before: [GraceChord], after: [GraceChord])? {
        guard case let .chord(chord)? = score[location], !chord.notes.isEmpty else { return nil }
        return (before: chord.graceNotesBefore, after: chord.graceNotesAfter)
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let element = score[location] else {
            throw Self.refused(.targetNotFound(location))
        }
        guard case var .chord(chord) = element, !chord.notes.isEmpty else {
            throw Self.refused(.wrongElementKind(at: location, expected: .chord))
        }
        let inverse = SetGraceNotes(
            at: location, before: chord.graceNotesBefore, after: chord.graceNotesAfter,
        )
        chord.graceNotesBefore = before
        chord.graceNotesAfter = after
        score[location] = .chord(chord)
        return inverse
    }
}
