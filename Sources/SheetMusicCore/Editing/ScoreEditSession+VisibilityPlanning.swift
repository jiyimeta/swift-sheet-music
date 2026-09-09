import SheetMusicFoundation

/// `ScoreEditSession`'s planning half for the parity project's visibility intents (58…61), and for the engraved
/// text's own visibility (75), which joined them because it is the same operation on a different address. Its own
/// file for the reason `+MarkPlanning.swift` exists: `+Planning.swift` sits at its line budget.
///
/// Every planner here follows the standing rule: an intent that restates what the score already says plans to
/// `nil` (`.nothingToApply`), never to a self-restoring undo entry. Each reads the score through the command's own
/// `current…` accessor, so "already says" is decided by the same lookup the command's `apply` performs. Kind and
/// range refusals stay in `apply`, so a command built directly answers the same way.
///
/// `setBeamVisible` is the one intent whose command is not built at the slot the intent names: the beam flag lives
/// on the group's LEADING chord (`Chord.beamVisible`), so the host may name any member and the command is aimed at
/// the leader `BeamGrouping` finds — the rule the layout beams with. Both images run this re-target, which is why
/// the wire carries the host's slot and not the leader's. A chord in no group keeps its own slot and `apply`
/// raises `.notBeamed`.
extension ScoreEditSession {
    static func visibilityCommand(for intent: EditIntent, in score: Score) -> (any EditCommand)? {
        switch intent {
        case let .setElementVisible(location, visible):
            return SetElementVisible.current(at: location, in: score) == visible
                ? nil : SetElementVisible(at: location, visible: visible)
        case let .setNoteVisible(location, visible):
            return SetNoteVisible.current(at: location, in: score) == visible
                ? nil : SetNoteVisible(at: location, visible: visible)
        case let .setStemVisible(location, visible):
            return SetStemVisible.current(at: location, in: score) == visible
                ? nil : SetStemVisible(at: location, visible: visible)
        case let .setBeamVisible(location, visible):
            guard SetBeamVisible.current(at: location, in: score) != visible else { return nil }
            let leader = SetBeamVisible.leader(of: location, in: score) ?? location
            return SetBeamVisible(at: leader, visible: visible)
        case let .setTextVisible(text, visible):
            // A text the score does not carry reads `nil` here, which is NOT equal to `visible` and so plans a
            // command — deliberately, so a stale selection is refused by `apply` as `.targetNotFound` rather than
            // silently reported as nothing to apply. Only a text that really reads this way already plans to nil.
            return SetTextVisible.current(text, in: score) == visible
                ? nil : SetTextVisible(text, visible: visible)
        default:
            // Reached only through `command(for:in:depth:)`'s grouped case, which already narrows the intent;
            // the `default` exists because that narrowing is a `case` list, not a type.
            return nil
        }
    }
}
