import SheetMusicFoundation

/// Sets one duration on every chord and rest in a range — MuseScore's 1…7 keys over a range selection, as one
/// undo step.
///
/// Elements are re-timed in ascending onset order, each re-found by its tick in the score the previous re-timing
/// produced, and an onset a lengthening has already swallowed is skipped: `[q q q q]` to half is `[h h]`, to whole
/// is `[w]`, to eighth is `[e r e r e r e r]`. Refused whole, before anything is planned, when any element in the
/// range is inside a tuplet — a member's length is the tuplet's to decide — and when `.measure` (a rest-only
/// spelling) is asked of a chord. Any per-element refusal (`insufficientRoom` at a barline, an untimed element in
/// the way) refuses the whole range; nothing is written.
///
/// > Note: This command is sugar over `SetChordDuration` / `SetRestDuration` (× element) bundled in a
/// > `CompositeEditCommand` by `RangeEditPlanner`. It exists to give the operation a domain-meaningful name and to
/// > own the ascending-onset rule; callers can equally construct the equivalent Composite directly. See
/// > `docs/edit-commands.md`.
public struct SetDurationInRange: EditCommand {
    public let range: VoiceElementRange
    public let duration: NoteDuration

    public init(over range: VoiceElementRange, duration: NoteDuration) {
        self.range = range
        self.duration = duration
    }

    public var affectedLocation: VoiceElementID {
        range.start
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let composite = try plan(in: score) else {
            return CompositeEditCommand(commands: [], location: range.start)
        }
        return try composite.apply(to: &score)
    }

    /// The composite this command would apply to `score`, or `nil` when it would change nothing — what the
    /// session's planner reads as "restating is nil". Validation happens here so a direct `apply` and a planned one
    /// refuse identically.
    func plan(in score: Score) throws -> CompositeEditCommand? {
        let targets = score.voiceElements(in: range)
        guard !targets.isEmpty else { throw Self.refused(.targetNotFound(range.start)) }
        try ensureWritable(targets, in: score)
        return try RangeEditPlanner.plan(over: range, in: score) { target, working in
            guard case let .chord(timed)? = working[target] else { return [] }
            let measureDuration = working.effectiveMeasureDuration(at: target.staff, measureIndex: target.measureIndex)
            let current = timed.duration.resolved(in: measureDuration).ticks(division: working.division)
            let wanted = duration.resolved(in: measureDuration).ticks(division: working.division)
            guard current != wanted else { return [] }
            return timed.notes.isEmpty
                ? [SetRestDuration(at: target, duration: duration)]
                : [SetChordDuration(at: target, duration: duration)]
        }?.composite
    }

    /// The two wholesale refusals, decided against the untouched score so the first offender is named and nothing
    /// has been planned when they fire.
    private func ensureWritable(_ targets: [VoiceElementID], in score: Score) throws {
        for target in targets {
            guard let voice = DurationChangeAlgorithm.voice(in: score, at: target) else { continue }
            try DurationChangeAlgorithm.ensureNotInsideTuplet(
                voice: voice, at: target, operation: String(describing: Self.self),
            )
            if case .measure = duration, case let .chord(chord)? = score[target], !chord.notes.isEmpty {
                throw Self.refused(.wrongElementKind(at: target, expected: .rest))
            }
        }
    }
}
