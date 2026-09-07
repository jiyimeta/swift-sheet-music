import SheetMusicFoundation

/// `ScoreEditSession`'s planning half for the signature intents: `.setKeySignature` / `.removeKeySignature` and
/// `.setTimeSignature` / `.removeTimeSignature`.
///
/// Split off `ScoreEditSession+Planning.swift` when that file reached SwiftLint's 400-line budget — the same cut,
/// for the same reason, that produced it from `ScoreEditSession.swift`. The seam is a real one: every intent here
/// edits what a BAR DECLARES and then has to re-spell the span that declaration governs, which is a different piece
/// of reasoning from the note-level planning next door and shares nothing with it but the enclosing type.
///
/// `structuralCommand(for:in:)` over in the sibling file dispatches to these, so they are internal rather than
/// private; nothing outside this module calls them.
extension ScoreEditSession {
    /// `.setKeySignature`: the key write, plus the re-spelling of every bar that write silently re-reads.
    ///
    /// `nil` when that key is already the one in force at `measureIndex` — the score already says this, and
    /// planning it anyway would push an undo entry that restores the score to itself, the same dead ⌘Z `.movePart`
    /// refuses. A bar that declares its own key IS the key in force there (`Score.activeKey` reads the last
    /// declaration up to and including the bar), so this one test covers both "nothing to change" shapes: a bar
    /// with an explicit key already equal to `concertKey`, and a bar inheriting one that is.
    ///
    /// Also `nil` for a score with no pitched staff at all — a kit-only score declares no key anywhere, so there is
    /// nothing for this intent to change.
    ///
    /// The range is NOT validated here: `SetKeySignature.apply` states it once, and the preview inside
    /// `keyChangeCommand` is what surfaces its refusal.
    static func setKeySignatureCommand(
        at measureIndex: Int, concertKey: Int, in score: Score,
    ) throws -> (any EditCommand)? {
        guard let reference = KeySignatureStaves.reference(in: score),
              score.activeKey(staff: reference, measureIndex: measureIndex) != concertKey
        else { return nil }
        return try keyChangeCommand(SetKeySignature(measureIndex: measureIndex, concertKey: concertKey), in: score)
    }

    /// `.removeKeySignature`: the removal, plus the re-spelling of the span that reverts with it.
    ///
    /// `nil` when the bar declares no key of its own — there is no change there to remove, which is nothing to
    /// apply rather than a refusal. Measure 0 DOES declare one, so it reaches `RemoveKeySignature.apply` and comes
    /// back as `.cannotRemoveInitialSignature`; that refusal is the command's to state, not this planner's.
    static func removeKeySignatureCommand(
        at measureIndex: Int, in score: Score,
    ) throws -> (any EditCommand)? {
        guard let reference = KeySignatureStaves.reference(in: score),
              KeySignatureStaves.explicitKey(in: score, staff: reference, measureIndex: measureIndex) != nil
        else { return nil }
        return try keyChangeCommand(RemoveKeySignature(measureIndex: measureIndex), in: score)
    }

    /// `.setTimeSignature`: the meter write and the re-barring of the span it governs, as one command.
    ///
    /// `nil` when that meter is already the one in force at `measureIndex` — the score already says this, and
    /// planning it anyway would push an undo entry that restores the score to itself, the same dead ⌘Z
    /// `.setKeySignature` and `.movePart` both refuse. A bar that declares its own meter IS the meter in force
    /// there, so this one test covers both "nothing to change" shapes.
    ///
    /// Nothing is bundled onto the command here, unlike the key intents next door: a re-bar moves the BYTES of
    /// every bar in its region, so the session's own diff-driven `renotatingAccidentals` pass already reaches
    /// each of them and re-spells whatever the new barlines moved. The key intents need their span named
    /// explicitly precisely because they move only one bar's bytes while re-reading the rest.
    ///
    /// The range is NOT validated here: `SetTimeSignature.apply` states it once, and so are the numerator, the
    /// denominator and their pairing with `symbol` — an unwritable or mismatched signature is never equal to the
    /// one in force, so it reaches the command.
    static func setTimeSignatureCommand(
        at measureIndex: Int, numerator: Int, denominator: Int,
        symbol: TimeSignatureSymbol, in score: Score,
    ) -> (any EditCommand)? {
        let inForce = TimeSignatureRegion.signature(inForceAt: measureIndex, in: score)
        // The symbol is part of what the bar declares, so swapping "4/4" for a C is a change even though the
        // meter is untouched — the region re-bars to the same barlines and the glyph is what moves.
        guard inForce.numerator != numerator
            || inForce.denominator != denominator
            || inForce.symbol != symbol
        else { return nil }
        return SetTimeSignature(
            measureIndex: measureIndex, numerator: numerator, denominator: denominator, symbol: symbol,
        )
    }

    /// `.removeTimeSignature`: the removal, plus the re-barring of the span that reverts with it.
    ///
    /// `nil` when the bar declares no meter of its own — there is no change there to remove, which is nothing to
    /// apply rather than a refusal. Measure 0 DOES declare one, so it reaches `RemoveTimeSignature.apply` and
    /// comes back as `.cannotRemoveInitialSignature`; that refusal is the command's to state, not this planner's.
    static func removeTimeSignatureCommand(at measureIndex: Int, in score: Score) -> (any EditCommand)? {
        guard measureIndex == 0
            || TimeSignatureRegion.explicitSignature(in: score, measureIndex: measureIndex) != nil
        else { return nil }
        return RemoveTimeSignature(measureIndex: measureIndex)
    }

    /// `command` bundled with the glyph repairs the span it governs needs, as one undo step.
    ///
    /// The repairs are planned against a PREVIEW that already carries the new key: `MeasureAccidentals`' range form
    /// judges each note against the signature the score it is handed declares, so planning against the pre-edit
    /// score would re-spell the span for the key being REPLACED — a pass that finds every glyph already correct and
    /// leaves all of them wrong.
    ///
    /// The span runs from the changed bar to the next bar that declares its own key, because that is exactly how
    /// far the new key reaches. It is read from the preview too: a removal deletes a declaration, and the bars it
    /// hands back to the previous key are the ones the pre-edit score would have stopped at.
    ///
    /// The session wraps whatever comes back in its own diff-driven renotation pass, which then finds nothing left
    /// to fix — the two compose rather than fight. That diff alone could not do this job: a key change moves the
    /// bytes of ONE bar while silently re-reading every bar after it.
    private static func keyChangeCommand(_ command: any EditCommand, in score: Score) throws -> any EditCommand {
        var preview = score
        try command.apply(to: &preview)
        let measureIndex = command.affectedLocation.measureIndex
        // `apply` has accepted the index, so `measureIndex` names a real bar and the range below is never empty.
        let end = nextExplicitKeyChange(after: measureIndex, in: preview)
            ?? MeasureStructure.measureCount(of: preview)
        return CompositeEditCommand(
            commands: [command] + MeasureAccidentals.renotationCommands(
                in: preview, measureRange: measureIndex ..< end,
            ),
            location: command.affectedLocation,
        )
    }

    /// The first bar after `measureIndex` whose reference staff declares a key of its own — where a key written at
    /// `measureIndex` stops being the one in force. `nil` when no later bar declares one.
    private static func nextExplicitKeyChange(after measureIndex: Int, in score: Score) -> Int? {
        guard let reference = KeySignatureStaves.reference(in: score), let staff = score[reference] else {
            return nil
        }
        let start = max(measureIndex + 1, 0)
        guard start < staff.measures.count else { return nil }
        return (start ..< staff.measures.count).first {
            KeySignatureStaves.explicitKey(in: score, staff: reference, measureIndex: $0) != nil
        }
    }
}
