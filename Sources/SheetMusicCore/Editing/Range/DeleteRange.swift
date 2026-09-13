import SheetMusicFoundation

/// Turns everything the range covers into rests, and touches nothing outside it.
///
/// The unit of work is one `(staff, measure, voice)` at a time: the slots the range covers there are replaced by the
/// rests that spell their COMBINED length on the metric grid (`DurationChangeAlgorithm.alignedDurations`), so two
/// dotted eighths deleted together come back as a quarter rest plus an eighth rest rather than two dotted eighth
/// rests. Slots the range does not cover — notes and rests alike — are carried over untouched, which is the whole
/// point: a bar holding a half note and a half rest gives back two half rests when only the note is deleted, not the
/// measure rest the collapse used to produce by swallowing a rest nobody had selected.
///
/// The one exception is total coverage: when the range covers every timed slot of a bar-voice, the bar is silent and
/// is spelled the way MuseScore spells a silent bar — one `.measure` rest, tuplets dissolved
/// (`FullMeasureRestCollapse`). That rule is about COVERAGE, not about what happens to survive, so it fires for a
/// range of nothing but rests too: selecting a bar's two half rests and deleting collapses them to a measure rest.
///
/// Rests are re-spelled like anything else the range covers, but a run whose fill lands on the very same lengths it
/// replaced keeps each rest's identifier and its original spelling — so a `.measure` rest the range covered stays a
/// `.measure` rest instead of being rewritten as the literal `.whole` that totals the same ticks.
///
/// Tuplet members are the other thing the fill leaves alone: a covered member becomes a rest of its OWN length and
/// the bracket survives, because folding a tuplet's slots into a plain metric fill would be dissolving the tuplet,
/// which is not what deleting its notes means. (A range covering the whole bar-voice still collapses, tuplet and
/// all — that path is the measure rest above.)
///
/// A tie running into a deleted chord is left dangling exactly as `.delete` leaves it — no chain repair here, so the
/// two paths produce the same score.
///
/// > Note: This command is sugar over one `ReplaceVoiceElements` per touched bar-voice, bundled in a
/// > `CompositeEditCommand`. It exists to give the operation a domain-meaningful name and to own the fill and
/// > collapse rules; callers can equally construct the equivalent Composite directly. See `docs/edit-commands.md`.
public struct DeleteRange: EditCommand {
    public let range: VoiceElementRange

    public init(over range: VoiceElementRange) {
        self.range = range
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
        try detailedPlan(in: score, ids: ids)?.composite
    }

    /// The complete post-delete scratch state and the commands that reproduce it — one `ReplaceVoiceElements` per
    /// bar-voice the range touched, in the order the range reached them.
    func detailedPlan(in score: Score, ids: EIDAllocator) throws -> RangeEditPlanner.Plan? {
        let targets = score.voiceElements(in: range)
        guard !targets.isEmpty else { throw Self.refused(.targetNotFound(range.start)) }

        var commands: [any EditCommand] = []
        var working = score
        var scratch = ids
        var location: VoiceElementID?
        for (ref, covered) in Self.grouped(targets) {
            guard let rewrite = Self.rewrite(voice: ref, clearing: covered, in: working) else { continue }
            _ = try rewrite.command.apply(to: &working, ids: &scratch)
            commands.append(rewrite.command)
            location = location ?? VoiceElementID(
                staff: ref.staff, measureIndex: ref.measureIndex,
                voiceIndex: ref.voiceIndex, elementIndex: rewrite.restElementIndex,
            )
        }
        guard let location, !commands.isEmpty else { return nil }
        return RangeEditPlanner.Plan(
            commands: commands, location: location, result: working, idAllocator: scratch,
        )
    }

    /// The covered element indices per bar-voice, in the order the range first reached each one — so the composite's
    /// reported location is the first rest of the first voice the range touched, the same slot a caller would want
    /// the selection to land on.
    private static func grouped(_ targets: [VoiceElementID]) -> [(ref: VoiceRef, covered: Set<Int>)] {
        var order: [VoiceRef] = []
        var covered: [VoiceRef: Set<Int>] = [:]
        for target in targets {
            let ref = VoiceRef(target)
            if covered[ref] == nil { order.append(ref) }
            covered[ref, default: []].insert(target.elementIndex)
        }
        return order.map { ($0, covered[$0] ?? []) }
    }

    private struct Rewrite {
        let command: ReplaceVoiceElements
        let restElementIndex: Int
    }

    /// One bar-voice rewritten, or `nil` when clearing `covered` there would change nothing.
    private static func rewrite(voice ref: VoiceRef, clearing covered: Set<Int>, in score: Score) -> Rewrite? {
        if let collapse = FullMeasureRestCollapse.plan(clearing: covered, in: ref, of: score) {
            return Rewrite(command: collapse.command, restElementIndex: collapse.restElementIndex)
        }
        guard let voice = score[voice: ref] else { return nil }
        let division = score.division
        let measureDuration = score.effectiveMeasureDuration(at: ref.staff, measureIndex: ref.measureIndex)
        let spans = voice.tupletSpans

        var builder = RestFillBuilder(division: division)
        var rtick = 0
        for (index, element) in voice.elements.enumerated() {
            let kept = SlotIdentity.keep(voice.elements.eid(at: index))
            defer { rtick += element.cursorAdvance(division: division, in: measureDuration) }
            guard case let .chord(chord) = element, covered.contains(index) else {
                builder.carryOver(at: index, identity: kept, element: element)
                continue
            }
            if spans.contains(where: { $0.startIndex <= index && index <= $0.endIndex }) {
                // Inside a tuplet the bracket's arithmetic is what fixes the spelling: the member keeps its own
                // length and only loses its notes.
                builder.clearInPlace(at: index, identity: kept, chord: chord)
            } else {
                builder.absorb(
                    rtick: rtick, ticks: chord.duration.resolved(in: measureDuration).ticks(division: division),
                    duration: chord.duration, identity: kept, wasRest: chord.notes.isEmpty,
                )
            }
        }
        builder.flush()

        let tupletSlots = surviving(spans, of: voice, under: builder.newIndexForOldIndex)
        guard builder.slots.map(\.element) != voice.elements.values
            || tupletSlots.count != voice.tuplets.count,
            let restElementIndex = builder.firstRestIndex
        else { return nil }
        return Rewrite(
            command: ReplaceVoiceElements(
                staff: ref.staff, measureIndex: ref.measureIndex, voiceIndex: ref.voiceIndex,
                slots: builder.slots, tupletSlots: tupletSlots,
            ),
            restElementIndex: restElementIndex,
        )
    }

    /// The voice's tuplets with their endpoints re-pointed at the rewritten element list. A tuplet whose endpoints
    /// were folded into a fill has no members left to bracket and is dropped — which the fill never does, since
    /// tuplet members are cleared in place.
    private static func surviving(
        _ spans: [TupletSpan], of voice: Voice, under newIndex: [Int: Int],
    ) -> [TupletSlot] {
        spans.indices.compactMap { index in
            guard let first = newIndex[spans[index].startIndex], let last = newIndex[spans[index].endIndex]
            else { return nil }
            var tuplet = voice.tuplets[index]
            tuplet.first = .index(first)
            tuplet.last = .index(last)
            return TupletSlot(identity: .keep(voice.tuplets.eid(at: index)), tuplet: tuplet)
        }
    }
}

/// Builds one bar-voice's replacement element list for `DeleteRange`: slots the range did not cover pass through,
/// slots it did cover accumulate into runs that are re-spelled as metric-aligned rests.
///
/// A run ends wherever something that is not an absorbed slot intervenes — a surviving chord, a clef, a tuplet
/// member — so a clef inside the deleted span keeps its exact tick instead of being pushed to the next rest
/// boundary by a fill that spanned it.
private struct RestFillBuilder {
    let division: Int
    private(set) var slots: [VoiceSlot] = []
    /// Where each carried-over or cleared-in-place element landed, so a tuplet's endpoints can be re-pointed.
    private(set) var newIndexForOldIndex: [Int: Int] = [:]
    /// The first slot this rewrite produced — where a caller lands the selection after the delete.
    private(set) var firstRestIndex: Int?

    private var runStart = 0
    private var runTicks = 0
    private var run: [(ticks: Int, duration: NoteDuration, identity: SlotIdentity, wasRest: Bool)] = []

    init(division: Int) {
        self.division = division
    }

    mutating func carryOver(at index: Int, identity: SlotIdentity, element: VoiceElement) {
        flush()
        newIndexForOldIndex[index] = slots.count
        slots.append(VoiceSlot(identity: identity, element: element))
    }

    mutating func clearInPlace(at index: Int, identity: SlotIdentity, chord: Chord) {
        flush()
        newIndexForOldIndex[index] = slots.count
        guard !chord.notes.isEmpty else {
            slots.append(VoiceSlot(identity: identity, element: .chord(chord)))
            return
        }
        appendRest(.rest(duration: chord.duration), identity: .fresh)
    }

    mutating func absorb(
        rtick: Int, ticks: Int, duration: NoteDuration, identity: SlotIdentity, wasRest: Bool,
    ) {
        if run.isEmpty { runStart = rtick }
        runTicks += ticks
        run.append((ticks, duration, identity, wasRest))
    }

    mutating func flush() {
        guard !run.isEmpty else { return }
        defer { run = []; runTicks = 0 }
        let durations = DurationChangeAlgorithm.alignedDurations(
            forTicks: runTicks, rtickStart: runStart, division: division,
        )
        // A fill that lands on the very lengths it replaced is not a re-spelling at all — every slot keeps the
        // spelling it had (so a `.measure` rest is not rewritten as the `.whole` that totals the same ticks) and
        // every rest keeps its identifier. Only a chord's slot has to mint one, because its content changed.
        let unchanged = durations.count == run.count
            && zip(durations, run).allSatisfy { $0.ticks(division: division) == $1.ticks }
        guard unchanged else {
            for duration in durations {
                appendRest(.rest(duration: duration), identity: .fresh)
            }
            return
        }
        for slot in run {
            appendRest(.rest(duration: slot.duration), identity: slot.wasRest ? slot.identity : .fresh)
        }
    }

    private mutating func appendRest(_ element: VoiceElement, identity: SlotIdentity) {
        if firstRestIndex == nil { firstRestIndex = slots.count }
        slots.append(VoiceSlot(identity: identity, element: element))
    }
}
