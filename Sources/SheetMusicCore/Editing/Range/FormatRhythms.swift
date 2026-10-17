import SheetMusicFoundation

/// Where `FormatRhythms` works.
public enum FormatRhythmsScope: Sendable, Equatable {
    /// Every staff, every bar, every voice.
    case score
    /// The staves and voices `range` covers, and only the spans lying ENTIRELY inside its onset window: a span
    /// crossing the edge is left as written, because clipping it would tie into untouched territory.
    case range(VoiceElementRange)
    /// One bar of one staff, every voice — what a click or a caret with no range means.
    case measure(staff: StaffAddress, measureIndex: Int)
}

/// Re-spells durations over a scope without changing what sounds: tied chains of bare continuations are regrouped on
/// the metric grid, runs of rests are re-spelled, and everything else — tuplets, anything whose sound depends on its
/// length, measure rests — is carried over as written. The per-bar-voice rules live in `FormatRhythmsBarPlanner`;
/// this command owns the scope, the bar facts (meter, pickup, window, protected onsets) and the bundling.
///
/// > Note: This command is sugar over one `ReplaceVoiceElements` per changed bar-voice, bundled in a
/// > `CompositeEditCommand`. It exists to give the operation a domain-meaningful name and to own the scope and bar
/// > rules; callers can equally construct the equivalent Composite directly. See `docs/edit-commands.md`.
public struct FormatRhythms: EditCommand {
    public let scope: FormatRhythmsScope
    public let policy: RhythmSpellingPolicy

    public init(scope: FormatRhythmsScope, policy: RhythmSpellingPolicy) {
        self.scope = scope
        self.policy = policy
    }

    /// The head of the score when nothing is planned. A command's affected location is a pure function of its
    /// inputs, and which element is rewritten first depends on the score; the planned composite (what the session
    /// hands back) carries that answer instead.
    public var affectedLocation: VoiceElementID {
        Self.origin
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let composite = try plan(in: score, ids: ids) else {
            return CompositeEditCommand(commands: [], location: affectedLocation)
        }
        return try composite.apply(to: &score, ids: &ids)
    }

    /// The composite this command would apply to `score`, or `nil` when it would change nothing — what the
    /// session's planner reads as "restating is nil". Validation happens here so a direct `apply` and a planned one
    /// refuse identically. Its location is the first element the plan rewrites.
    func plan(in score: Score, ids: EIDAllocator) throws -> CompositeEditCommand? {
        let region = try resolveRegion(in: score)
        let protected = FormatRhythmsProtectedOnsets.collect(in: score)
        var commands: [any EditCommand] = []
        var location: VoiceElementID?
        var working = score
        var scratch = ids
        for (address, staff) in score.allStaves where region.staves.contains(address) {
            let bars = FormatRhythmsBars(staff: staff, division: score.division)
            for measureIndex in staff.measures.indices where region.measures.contains(measureIndex) {
                let onsets = protected[FormatRhythmsProtectedOnsets.Bar(staff: address, measure: measureIndex)]
                guard let facts = bars.facts(
                    at: measureIndex, window: region.window(measureIndex, barTicks: bars.barTicks[measureIndex]),
                    protectedOnsets: onsets ?? [],
                ) else { continue }
                for (voiceIndex, voice) in staff.measures[measureIndex].voices.enumerated() {
                    guard let rewrite = FormatRhythmsBarPlanner.respell(voice, facts: facts, policy: policy) else {
                        continue
                    }
                    let command = ReplaceVoiceElements(
                        staff: address, measureIndex: measureIndex, voiceIndex: voiceIndex,
                        slots: rewrite.slots, tupletSlots: rewrite.tupletSlots,
                    )
                    _ = try command.apply(to: &working, ids: &scratch)
                    commands.append(command)
                    location = location ?? VoiceElementID(
                        staff: address, measureIndex: measureIndex, voiceIndex: voiceIndex,
                        elementIndex: Self.firstRewritten(rewrite.slots, in: voice),
                    )
                }
            }
        }
        guard let location, !commands.isEmpty else { return nil }
        return CompositeEditCommand(commands: commands, location: location)
    }

    private static let origin = VoiceElementID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0, voiceIndex: 0, elementIndex: 0,
    )

    /// The index of the first slot that is not the element it replaces: a fresh slot, or a kept one whose element
    /// changed (a head chord re-timed in place).
    private static func firstRewritten(_ slots: [VoiceSlot], in voice: Voice) -> Int {
        let old = voice.elements.values
        for (index, slot) in slots.enumerated() {
            if case .fresh = slot.identity { return index }
            if !old.indices.contains(index) || old[index] != slot.element { return index }
        }
        return 0
    }

    // MARK: Scope

    /// The staves and bars the scope reaches, and — for a range — the onset window inside them.
    private struct Region {
        var staves: Set<StaffAddress>
        var measures: ClosedRange<Int>
        var lower: ScoreTickPosition?
        var upper: ScoreTickPosition?

        /// The bar-relative window of `measure`, clipped to the bar; `nil` for a scope that takes whole bars.
        func window(_ measure: Int, barTicks: Int) -> Range<Int>? {
            guard let lower, let upper else { return nil }
            let start = measure == lower.measure ? lower.tick : 0
            let end = measure == upper.measure ? min(upper.tick, barTicks) : barTicks
            return start ..< max(start, end)
        }
    }

    private func resolveRegion(in score: Score) throws -> Region {
        switch scope {
        case .score:
            return Region(
                staves: Set(score.allStaves.map(\.address)), measures: 0 ... Int.max, lower: nil, upper: nil,
            )
        case let .measure(staff, measureIndex):
            guard let target = score[staff] else { throw Self.refused(.staffNotFound(staff)) }
            guard target.measures.indices.contains(measureIndex) else {
                throw Self.refused(.targetNotFound(VoiceElementID(
                    staff: staff, measureIndex: measureIndex, voiceIndex: 0, elementIndex: 0,
                )))
            }
            return Region(staves: [staff], measures: measureIndex ... measureIndex, lower: nil, upper: nil)
        case let .range(range):
            guard !score.voiceElements(in: range).isEmpty,
                  let startOnset = score.onset(of: range.start), let endOnset = score.onset(of: range.end),
                  let startEnd = score.end(of: range.start), let endEnd = score.end(of: range.end)
            else { throw Self.refused(.targetNotFound(range.start)) }
            let low = min(startOnset, endOnset)
            let high = max(startEnd, endEnd)
            let first = min(range.start.staff, range.end.staff)
            let last = max(range.start.staff, range.end.staff)
            return Region(
                staves: Set(score.allStaves.map(\.address).filter { (first ... last).contains($0) }),
                measures: low.measure ... high.measure, lower: low, upper: high,
            )
        }
    }
}
