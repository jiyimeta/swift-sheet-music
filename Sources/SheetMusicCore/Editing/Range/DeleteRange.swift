import SheetMusicFoundation

/// Replaces every chord in a range with a rest of the same length, then collapses each bar-voice the deletes left
/// all-rests into one measure rest — so a range delete and a click-delete of the same content produce the same
/// score. Rests already in the range are left alone; non-timed elements (clefs, signatures, barlines) are kept.
///
/// The collapse is planned against the post-delete score, per `(staff, measure, voice)` a delete touched, with
/// `FullMeasureRestCollapse` — the same plan `.delete` uses — so tuplets dissolve and `.measure` is the spelling,
/// not four quarter rests. The composite is ordered deletes first, collapses after, and the inverse unwinds it
/// exactly: the collapse's pre-image restores the rests, then each delete's pre-image restores its chord.
///
/// > Note: This command is sugar over `DeleteVoiceElement` (× chord) + `ReplaceVoiceElements` (× emptied voice)
/// > bundled in a `CompositeEditCommand` by `RangeEditPlanner`. It exists to give the operation a
/// > domain-meaningful name and to own the collapse rule; callers can equally construct the equivalent Composite
/// > directly. See `docs/edit-commands.md`.
public struct DeleteRange: EditCommand {
    public let range: VoiceElementRange

    public init(over range: VoiceElementRange) {
        self.range = range
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
        guard !score.voiceElements(in: range).isEmpty else { throw Self.refused(.targetNotFound(range.start)) }
        var touched: [VoiceRef] = []
        guard var plan = try RangeEditPlanner.plan(over: range, in: score, step: { target, working in
            guard case let .chord(chord)? = working[target], !chord.notes.isEmpty else { return [] }
            if !touched.contains(VoiceRef(target)) { touched.append(VoiceRef(target)) }
            return [DeleteVoiceElement(at: target)]
        }) else { return nil }
        for voice in touched {
            guard let first = plan.result.timedElementIndex(startingAt: 0, in: voice),
                  let collapse = FullMeasureRestCollapse.plan(
                      deleting: VoiceElementID(
                          staff: voice.staff, measureIndex: voice.measureIndex,
                          voiceIndex: voice.voiceIndex, elementIndex: first,
                      ),
                      in: plan.result,
                  )
            else { continue }
            _ = try collapse.command.apply(to: &plan.result)
            plan.commands.append(collapse.command)
        }
        return plan.composite
    }
}
