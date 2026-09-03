import SheetMusicFoundation

/// `ScoreEditSession`'s planning half for the parity project's spanner intents (62…72). Its own file for the
/// reason `+MarkPlanning.swift` and `+RangePlanning.swift` exist: `+Planning.swift` sits at its line budget.
///
/// Unlike every other planner in this project, none of these returns `nil`. The standing rule — an intent that
/// restates the score plans to `.nothingToApply` rather than to a self-restoring undo entry — is met here by the
/// engine instead: spec §3.2 makes a second spanner of the same kind at the same position a `.duplicateSpanner`
/// REFUSAL, which pushes no undo entry either. Deciding it in the planner would mean comparing the end the caller
/// asked for against the end the existing spanner records, and the caller's end is not known until
/// `SpannerPlacement` has resolved the range — so the planner would either duplicate the engine or answer a
/// different question. `removeSpanner` passes through for the reason `removeClef` does: "nothing is there" is a
/// refusal the command raises.
extension ScoreEditSession {
    static func spannerCommand(for intent: EditIntent, in _: Score) -> (any EditCommand)? {
        switch intent {
        case let .setSlur(range): SetSlur(over: range)
        case let .setHairpin(range, subtype): SetHairpin(over: range, subtype: subtype)
        case let .setPedal(range): SetPedal(over: range)
        case let .setVolta(range, endings, text): SetVolta(over: range, endings: endings, text: text)
        case let .setOttava(range, subtype): SetOttava(over: range, subtype: subtype)
        case let .setTextLine(range, text): SetTextLine(over: range, text: text)
        case let .setTrill(range, type): SetTrill(over: range, type: type)
        case let .setVibrato(range, type): SetVibrato(over: range, type: type)
        case let .setPalmMute(range): SetPalmMute(over: range)
        case let .setLetRing(range): SetLetRing(over: range)
        case let .removeSpanner(location, kind): RemoveSpanner(at: location, kind: kind)
        default:
            // Reached only through `command(for:in:depth:)`'s grouped case, which already narrows the intent;
            // the `default` exists because that narrowing is a `case` list, not a type.
            nil
        }
    }
}
