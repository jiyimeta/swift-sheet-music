import SheetMusicFoundation

/// `ScoreEditSession`'s planning half for the parity project's range intents (35…40). Its own file for the reason
/// `+StructuralParityPlanning.swift` exists: `+Planning.swift` sits at its line budget.
///
/// One rule for all six: the command's own `plan(in:)` decides whether there is anything to do. `nil` from it is the
/// session's `.nothingToApply` (transposing by zero, deleting rests, re-timing a range already at that length);
/// a `plan` that THROWS is not swallowed into `nil` — the command is returned as it is, so the refusal is raised
/// again at apply time, where the session records it. An empty resolved range is such a refusal
/// (`.targetNotFound`), never a silent nothing: the intent named something that is not there.
extension ScoreEditSession {
    static func rangeCommand(for intent: EditIntent, in score: Score, ids: EIDAllocator) -> (any EditCommand)? {
        switch intent {
        case let .transposeRange(range, semitones, respellInKey):
            let command = TransposeRange(over: range, semitones: semitones, respellInKey: respellInKey)
            return unlessInert(command, in: score) { try command.plan(in: $0, ids: ids) }
        case let .addIntervalToSelection(range, steps):
            let command = AddIntervalToSelection(over: range, steps: steps)
            return unlessInert(command, in: score) { try command.plan(in: $0, ids: ids) }
        case let .deleteRange(range):
            let command = DeleteRange(over: range)
            // The one intent here that hands back the PLANNED COMPOSITE rather than the command. A command's
            // `affectedLocation` is a pure function of its inputs, so `DeleteRange` can only ever report
            // `range.start` — which is the ANCHOR of a backward-drawn range (Shift+← draws one), and, when the bar
            // collapses to a single measure rest, an element index that no longer exists. The composite carries the
            // planner's own answer instead: the first rest the delete actually wrote. That is the slot a host
            // collapses its range selection onto, so getting it wrong is visible, not bookkeeping.
            //
            // A plan that THROWS still falls back to the command, for the reason the doc comment above gives: the
            // refusal is the command's to raise at apply time, where the session records it.
            do {
                return try command.plan(in: score, ids: ids)
            } catch {
                return command
            }
        case let .setAccidentalsInRange(range, accidental):
            let command = SetAccidentalsInRange(over: range, accidental: accidental)
            return unlessInert(command, in: score) { try command.plan(in: $0, ids: ids) }
        case let .setDurationInRange(range, duration):
            let command = SetDurationInRange(over: range, duration: duration)
            return unlessInert(command, in: score) { try command.plan(in: $0, ids: ids) }
        case let .respellRange(range, mode):
            let command = RespellRange(over: range, mode: mode)
            return unlessInert(command, in: score) { try command.plan(in: $0, ids: ids) }
        default:
            // Reached only through `command(for:in:depth:)`'s grouped case, which already narrows the intent;
            // the `default` exists because that narrowing is a `case` list, not a type.
            return nil
        }
    }

    /// `command` unless its plan against `score` is empty. A plan that throws keeps the command: the refusal is the
    /// command's to raise at apply time, not this planner's to hide behind `.nothingToApply`.
    private static func unlessInert(
        _ command: any EditCommand, in score: Score,
        plan: (Score) throws -> CompositeEditCommand?,
    ) -> (any EditCommand)? {
        do {
            return try plan(score) == nil ? nil : command
        } catch {
            return command
        }
    }
}
