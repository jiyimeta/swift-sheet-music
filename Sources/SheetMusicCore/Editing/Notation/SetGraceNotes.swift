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
    private let restoration: Snapshot?

    private struct Snapshot: Sendable {
        let before: IdentifiedArray<GraceChord>
        let after: IdentifiedArray<GraceChord>
    }

    public init(at location: VoiceElementID, before: [GraceChord], after: [GraceChord]) {
        self.location = location
        self.before = before
        self.after = after
        restoration = nil
    }

    /// Undo and redo restore captured slots verbatim, never re-match their values.
    private init(at location: VoiceElementID, restoring chord: Chord) {
        self.location = location
        before = chord.graceNotesBefore.values
        after = chord.graceNotesAfter.values
        restoration = Snapshot(before: chord.graceNotesBefore, after: chord.graceNotesAfter)
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    /// The chord's two grace lists, or `nil` when `location` names no chord — what the planner compares against.
    static func current(at location: VoiceElementID, in score: Score) -> (before: [GraceChord], after: [GraceChord])? {
        guard case let .chord(chord)? = score[location], !chord.notes.isEmpty else { return nil }
        return (before: chord.graceNotesBefore.values, after: chord.graceNotesAfter.values)
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let element = score[location] else {
            throw Self.refused(.targetNotFound(location))
        }
        guard case var .chord(chord) = element, !chord.notes.isEmpty else {
            throw Self.refused(.wrongElementKind(at: location, expected: .chord))
        }
        let inverse = SetGraceNotes(at: location, restoring: chord)
        if let restoration {
            chord.graceNotesBefore = restoration.before
            chord.graceNotesAfter = restoration.after
        } else {
            chord.graceNotesBefore = Self.match(before, against: chord.graceNotesBefore, using: &ids)
            chord.graceNotesAfter = Self.match(after, against: chord.graceNotesAfter, using: &ids)
        }
        score[location] = .chord(chord)
        return inverse
    }

    /// First unused equal value wins; duplicate values consume distinct current slots in order.
    ///
    /// A matched slot keeps the CURRENT value, not the caller's — `GraceChord` equality (like
    /// `ChordNotes`'s) ignores note identity, so a caller restating an unchanged grace as a fresh
    /// literal is value-equal to the existing slot while carrying unassigned note identifiers. Keeping
    /// `current[index]` preserves those without minting; only a genuinely new slot mints, and does so
    /// down to its own notes, matching `Chord.assignMissingNestedIDs`'s widened coverage.
    private static func match(
        _ wanted: [GraceChord], against current: IdentifiedArray<GraceChord>, using ids: inout EIDAllocator,
    ) -> IdentifiedArray<GraceChord> {
        var used: Set<Int> = []
        return IdentifiedArray(wanted.map { grace in
            if let index = current.indices.first(where: { !used.contains($0) && current[$0] == grace }) {
                used.insert(index)
                return (current.eid(at: index), current[index])
            }
            let eid = ids.next()
            var minted = grace
            minted.notes = ChordNotes(minted.notes.values) // a new slot is new notes
            minted.notes.assignMissingIDs(using: &ids)
            return (eid, minted)
        })
    }
}
