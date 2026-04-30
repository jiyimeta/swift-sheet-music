import Foundation

/// Sets the `tieForward` field on one note and the `tieBack` field
/// on another. Used to add or remove a tie between two adjacent
/// notes in the same voice.
///
/// Pass `sourceTieForward: nil` and `targetTieBack: nil` to remove
/// the tie. Pass matching `Int` values to add one (number 1 is the
/// default tie identifier when the two notes carry no other ties).
///
/// The inverse is another `SetTie` carrying the prior values, so
/// this command always round-trips cleanly even when the prior tie
/// state was asymmetric (e.g. a half-decoded score where only one
/// side of a tie was recorded).
public struct SetTie: EditCommand {
    public let sourceID: NoteID
    public let targetID: NoteID
    public let sourceTieForward: Int?
    public let targetTieBack: Int?

    public init(
        from sourceID: NoteID,
        to targetID: NoteID,
        sourceTieForward: Int?,
        targetTieBack: Int?
    ) {
        self.sourceID = sourceID
        self.targetID = targetID
        self.sourceTieForward = sourceTieForward
        self.targetTieBack = targetTieBack
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(sourceID)
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let oldSource = score[sourceID] else {
            throw SheetMusicError.invalidEdit(
                reason: "SetTie: no note at source \(sourceID)")
        }
        guard let oldTarget = score[targetID] else {
            throw SheetMusicError.invalidEdit(
                reason: "SetTie: no note at target \(targetID)")
        }
        let priorSourceForward = oldSource.tieForward
        let priorTargetBack = oldTarget.tieBack
        try Self.update(
            score: &score, noteID: sourceID,
            mutate: { $0.tieForward = sourceTieForward })
        try Self.update(
            score: &score, noteID: targetID,
            mutate: { $0.tieBack = targetTieBack })
        return SetTie(
            from: sourceID, to: targetID,
            sourceTieForward: priorSourceForward,
            targetTieBack: priorTargetBack)
    }

    private static func update(
        score: inout Score,
        noteID: NoteID,
        mutate: (inout Note) -> Void
    ) throws {
        let veID = VoiceElementID(noteID)
        guard case var .chord(chord) = score[veID] else {
            throw SheetMusicError.invalidEdit(
                reason: "SetTie: element at \(veID) is not a chord")
        }
        guard chord.notes.indices
            .contains(noteID.noteIndexInChord) else {
            throw SheetMusicError.invalidEdit(
                reason: "SetTie: noteIndex out of range at \(noteID)")
        }
        var note = chord.notes[noteID.noteIndexInChord]
        mutate(&note)
        chord.notes[noteID.noteIndexInChord] = note
        score[veID] = .chord(chord)
    }
}
