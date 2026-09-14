import SheetMusicFoundation

/// Sets one augmentation-dot count on every chord and rest in a range — MuseScore's `.` key over a range
/// selection, as one undo step.
///
/// The range form of `SetDots`, and the reason it cannot be spelled as `SetDurationInRange`: a dot count is not a
/// length. Each slot keeps the BASE it is spelled with today (`NoteDuration.baseAndDots()`) and only the dots move,
/// so a range holding a quarter and an eighth becomes a dotted quarter and a dotted eighth rather than two of the
/// same thing. `dots: 0` is a real value — it removes the dots.
///
/// Elements are re-timed in ascending onset order, each re-found by its tick in the score the previous re-timing
/// produced, and an onset a lengthening has already swallowed is skipped — the rule `SetDurationInRange` states,
/// and the reason this is a range command rather than a `SetDots` per element built by the host: dotting
/// `[q q q q]` consumes each following slot in turn, so the answer depends on the order they are written in.
///
/// Refused whole, before anything is planned, when any element in the range is inside a tuplet — a member's length
/// is the tuplet's to decide — and when `dots` is outside the 0…3 this package writes. Any per-element refusal
/// (`insufficientRoom` at a barline, an untimed element in the way) refuses the whole range; nothing is written.
///
/// A slot whose length has NO dotted spelling is skipped rather than refused: a `.measure` rest has no intrinsic
/// length to dot, and an empty bar is an ordinary thing to find inside a range — one of them must not take the
/// whole command down with it. `SetDots` refuses the same slot with `.notDottable` because there that slot IS the
/// target, and a command asked for one thing that cannot be done has nothing left to do.
///
/// > Note: This command is sugar over `SetChordDuration` / `SetRestDuration` (× element) bundled in a
/// > `CompositeEditCommand` by `RangeEditPlanner`, exactly as `SetDots` is for one element. See
/// > `docs/edit-commands.md`.
public struct SetDotsInRange: EditCommand {
    public let range: VoiceElementRange
    public let dots: Int

    public init(over range: VoiceElementRange, dots: Int) {
        self.range = range
        self.dots = dots
    }

    public var affectedLocation: VoiceElementID {
        range.start
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let composite = try plan(in: score, ids: ids) else {
            return CompositeEditCommand(commands: [], location: range.start)
        }
        return try composite.apply(to: &score, ids: &ids)
    }

    /// The composite this command would apply to `score`, or `nil` when it would change nothing — what the
    /// session's planner reads as "restating is nil". Validation happens here so a direct `apply` and a planned one
    /// refuse identically.
    func plan(in score: Score, ids: EIDAllocator) throws -> CompositeEditCommand? {
        let targets = score.voiceElements(in: range)
        guard !targets.isEmpty else { throw Self.refused(.targetNotFound(range.start)) }
        guard (0 ... 3).contains(dots) else { throw Self.refused(.notDottable(at: range.start)) }
        try ensureWritable(targets, in: score)
        return try RangeEditPlanner.plan(over: range, in: score, ids: ids) { target, working in
            guard case let .chord(timed)? = working[target],
                  let decomposed = timed.duration.baseAndDots(), decomposed.dots != dots
            else { return [] }
            let duration = decomposed.base.dotted(dots)
            return timed.notes.isEmpty
                ? [SetRestDuration(at: target, duration: duration)]
                : [SetChordDuration(at: target, duration: duration)]
        }?.composite
    }

    /// The wholesale tuplet refusal, decided against the untouched score so the first offender is named and nothing
    /// has been planned when it fires — the same guard `SetDurationInRange` opens with, for the same reason.
    private func ensureWritable(_ targets: [VoiceElementID], in score: Score) throws {
        for target in targets {
            guard let voice = DurationChangeAlgorithm.voice(in: score, at: target) else { continue }
            try DurationChangeAlgorithm.ensureNotInsideTuplet(
                voice: voice, at: target, operation: String(describing: Self.self),
            )
        }
    }
}
