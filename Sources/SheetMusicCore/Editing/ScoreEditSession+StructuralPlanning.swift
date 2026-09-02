import SheetMusicFoundation

/// Split out of `ScoreEditSession+Planning.swift` to keep that file under SwiftLint's 400-line budget as the edit
/// parity groups add to it; no behavior change from the move.
extension ScoreEditSession {
    /// The nine intents that change the score's shape: the measure columns, the parts, what a bar declares, and the
    /// rehearsal mark it carries.
    ///
    /// Reached only via `command(for:in:depth:)`'s combined case above, so — exactly like `directNoteEditCommand`
    /// — the `if case` chain below never needs to handle the intents that function keeps for itself.
    static func structuralCommand(for intent: EditIntent, in score: Score) throws -> (any EditCommand)? {
        if case let .insertMeasure(index) = intent {
            return InsertMeasure(measureIndex: index)
        }
        if case let .deleteMeasure(index) = intent {
            return DeleteMeasure(measureIndex: index)
        }
        if case let .addPart(plan, index) = intent {
            return AddPart(plan: plan, at: index)
        }
        if case let .removePart(index) = intent {
            return RemovePart(partIndex: index)
        }
        if case let .movePart(from, to) = intent {
            // A move onto its own index is a no-op, and planning it into a command would push an undo entry that
            // restores the score to itself — a dead ⌘Z the user has to press twice. `nil` reports it the way an
            // empty composite is reported, as `.nothingToApply`. Out-of-range indices are deliberately NOT caught
            // here: `MovePart.apply` states the range once, so the answer is the same however it is reached.
            return from == to ? nil : MovePart(from: from, to: to)
        }
        if case let .setPartNames(index, longName, shortName) = intent {
            // A rename to the names a part already has restores the score to itself — nothing to apply, the rule the
            // move above follows. An out-of-range index falls through to `SetPartNames.apply`, which states it once.
            let instrument = score.parts.indices.contains(index) ? score.parts[index].instrument : nil
            let unchanged = instrument.map { $0.longName == longName && $0.shortName == shortName } ?? false
            return unchanged ? nil : SetPartNames(partIndex: index, longName: longName, shortName: shortName)
        }
        if case let .setKeySignature(measureIndex, concertKey) = intent {
            return try setKeySignatureCommand(at: measureIndex, concertKey: concertKey, in: score)
        }
        if case let .removeKeySignature(measureIndex) = intent {
            return try removeKeySignatureCommand(at: measureIndex, in: score)
        }
        if case let .setRehearsalMark(measureIndex, text) = intent {
            return setRehearsalMarkCommand(at: measureIndex, text: text, in: score)
        }
        if case let .removeRehearsalMark(measureIndex) = intent {
            return removeRehearsalMarkCommand(at: measureIndex, in: score)
        }
        return nil
    }
}
