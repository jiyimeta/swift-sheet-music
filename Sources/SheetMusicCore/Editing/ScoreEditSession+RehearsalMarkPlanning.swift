import SheetMusicFoundation

/// `ScoreEditSession`'s planning half for the rehearsal-mark intents.
///
/// Its own file rather than another block in `ScoreEditSession+SignaturePlanning.swift`, and for the reason that
/// file gives for existing at all: `+Planning.swift` is at 345 of SwiftLint's 400 lines, and a rehearsal mark is a
/// SYSTEM element rather than something a bar declares, so it shares no reasoning with the signature planners next
/// door beyond addressing a bar.
///
/// `structuralCommand(for:in:)` dispatches to these, so they are internal rather than private; nothing outside this
/// module calls them.
extension ScoreEditSession {
    /// `.setRehearsalMark`: write the text, unless the bar already carries exactly it.
    ///
    /// `nil` in that case — the score already says this, and planning it anyway would push an undo entry that
    /// restores the score to itself, the dead ⌘Z `.setKeySignature` and `.movePart` both refuse. The comparison is
    /// made against the TRIMMED text, which is what the command would go on to write, so a re-submitted field with
    /// a stray trailing space is recognized as the no-op it is.
    ///
    /// Empty text is deliberately NOT caught here: `SetRehearsalMark.apply` states that rule, so a host gets the
    /// same `.emptyRehearsalMarkText` whether the command was reached through this intent or built directly.
    static func setRehearsalMarkCommand(
        at measureIndex: Int, text: String, in score: Score,
    ) -> (any EditCommand)? {
        // `SheetMusicFoundation`'s equivalent rather than `trimmingCharacters(in: .whitespacesAndNewlines)`:
        // `CharacterSet` is one of the pieces `FoundationEssentials` does not carry, so the Foundation spelling
        // does not compile for wasm at all. See that helper's doc comment.
        let trimmed = text.trimmingWhitespaceAndNewlines()
        guard RehearsalMarkLane.mark(in: score, measureIndex: measureIndex)?.text != trimmed else { return nil }
        return SetRehearsalMark(measureIndex: measureIndex, text: trimmed)
    }

    /// `.removeRehearsalMark`: the removal, or `nil` when the bar carries no mark to remove — nothing to apply
    /// rather than a refusal, the same split `removeKeySignatureCommand` makes.
    static func removeRehearsalMarkCommand(at measureIndex: Int, in score: Score) -> (any EditCommand)? {
        guard RehearsalMarkLane.mark(in: score, measureIndex: measureIndex) != nil else { return nil }
        return RemoveRehearsalMark(measureIndex: measureIndex)
    }
}
