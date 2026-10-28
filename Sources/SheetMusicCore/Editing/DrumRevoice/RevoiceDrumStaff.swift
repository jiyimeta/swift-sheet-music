import SheetMusicFoundation

/// What `RevoiceDrumStaff` would do to its staff, bar by bar, without doing it — what a host reads to tell the user
/// which bars the conversion left as written (design §4.7).
public struct RevoicePreview: Equatable, Sendable {
    /// The bars the conversion rewrites, ascending.
    public var rewrittenMeasures: [Int]
    /// The bars it cannot convert without changing what plays or losing a marking, ascending.
    public var measuresLeftAsWritten: [Int]
}

/// Re-voices a drum staff by pitch: every note moves to the voice `voiceForPitch` names for its pitch, and each bar is
/// rewritten so its notes sit there — one voice, or "hands and feet" with kicks and pedal hi-hat in voice 2 (design
/// 2026-10-26, drum voice conversion). The direction is only a choice of mapping.
///
/// A bar already in the target form is not touched (§4.6), so the command is idempotent and its undo holds only
/// what had to move; a bar that cannot be converted without changing what plays is left as written (§4.7) while
/// every other bar converts. The plan is a `CompositeEditCommand` of per-bar `CreateVoice` / `ReplaceVoiceElements`
/// / `RemoveVoice`, so applying and undoing it are those primitives' own.
public struct RevoiceDrumStaff: EditCommand {
    public let staff: StaffAddress
    /// Pitch → 0-based voice index. A pitch the map does not name goes to voice 0, and the highest index it names
    /// sets how many voices the target form has: an empty map is one voice.
    public let voiceForPitch: [Int: Int]
    /// The Format Rhythms policy a rewritten bar's rests are spelled with, carried in the command so every image of
    /// it plans the same rests.
    public let policy: RhythmSpellingPolicy

    public init(staff: StaffAddress, voiceForPitch: [Int: Int], policy: RhythmSpellingPolicy) {
        self.staff = staff
        self.voiceForPitch = voiceForPitch
        self.policy = policy
    }

    /// The staff's first bar. Which bar is rewritten first depends on the score; the planned composite (what the
    /// session hands back) carries that answer instead, as `FormatRhythms` does.
    public var affectedLocation: VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 0)
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let composite = try plan(in: score, ids: ids) else {
            return CompositeEditCommand(commands: [], location: affectedLocation)
        }
        return try composite.apply(to: &score, ids: &ids)
    }

    /// The bars this command would rewrite and the ones it would leave as written, from the same walk `apply`
    /// plans with. A staff the score does not have, or a mapping `apply` refuses, previews as nothing.
    public func preview(in score: Score) -> RevoicePreview {
        var preview = RevoicePreview(rewrittenMeasures: [], measuresLeftAsWritten: [])
        guard let target = try? validatedStaff(in: score) else { return preview }
        for (measureIndex, plan) in barPlans(of: target, division: score.division) {
            switch plan {
            case .untouched: continue
            case .leftAsWritten: preview.measuresLeftAsWritten.append(measureIndex)
            case .rewrite: preview.rewrittenMeasures.append(measureIndex)
            }
        }
        return preview
    }

    /// The composite this command would apply to `score`, or `nil` when no bar needs re-voicing — what the
    /// session's planner reads as "restating is nil". Validation happens here so a direct `apply` and a planned one
    /// refuse identically. As in `FormatRhythms.plan(in:ids:)`, every planned command is applied in order to a
    /// private copy of the score, so a plan the composite could not apply is refused here with the same error. Its
    /// location is the first rewritten bar's voice 0.
    func plan(in score: Score, ids: EIDAllocator) throws -> CompositeEditCommand? {
        let target = try validatedStaff(in: score)
        var planned: [any EditCommand] = []
        var location: VoiceElementID?
        var working = score
        var scratch = ids
        for (measureIndex, plan) in barPlans(of: target, division: score.division) {
            guard case let .rewrite(writes, voiceCountAfter) = plan else { continue }
            let commands = barCommands(
                writes, voiceCountAfter: voiceCountAfter, voiceCount: target.measures[measureIndex].voices.count,
                measureIndex: measureIndex,
            )
            for command in commands {
                _ = try command.apply(to: &working, ids: &scratch)
                planned.append(command)
            }
            guard !commands.isEmpty else { continue }
            location = location ?? VoiceElementID(
                staff: staff, measureIndex: measureIndex, voiceIndex: 0, elementIndex: 0,
            )
        }
        guard let location, !planned.isEmpty else { return nil }
        return CompositeEditCommand(commands: planned, location: location)
    }

    // MARK: Planning

    private func validatedStaff(in score: Score) throws -> Staff {
        guard let target = score[staff] else { throw Self.refused(.staffNotFound(staff)) }
        // A bar holds at most four voices.
        guard voiceForPitch.values.allSatisfy({ (0 ... 3).contains($0) }) else {
            throw Self.refused(.unexpected(description: "voice index out of range"))
        }
        return target
    }

    /// Every bar of `target` with its plan, in bar order. The staff's meters and lengths are read once for the walk.
    ///
    /// D6: a dynamic or hairpin that plays in its own voice only governs other notes once notes change voice, and its
    /// level holds until the voice's next dynamic, wherever that is. So from the bar of the staff's first such marking
    /// to the staff's end, a bar that would be rewritten is left as written instead (`.voiceOnlyDynamics`).
    private func barPlans(of target: Staff, division: Int) -> [(measureIndex: Int, plan: RevoiceBarPlan)] {
        let bars = FormatRhythmsBars(staff: target, division: division)
        let voiceOnlyFrom = target.measures.firstIndex(where: Self.holdsVoiceOnlyDynamic) ?? target.measures.count
        return target.measures.indices.map { measureIndex in
            let bar = RevoiceBar(staff: target, measureIndex: measureIndex, bars: bars)
            let plan = RevoiceBarPlanner.plan(bar, voiceForPitch: voiceForPitch, policy: policy)
            guard measureIndex >= voiceOnlyFrom, case .rewrite = plan else { return (measureIndex, plan) }
            return (measureIndex, .leftAsWritten(.voiceOnlyDynamics))
        }
    }

    /// The bar holds a dynamic, or a hairpin, assigned to its own voice only (`VoiceAssignment.currentVoiceOnly`).
    private static func holdsVoiceOnlyDynamic(_ measure: Measure) -> Bool {
        measure.voices.contains { voice in
            voice.elements.contains { element in
                switch element {
                case let .dynamic(dynamic): dynamic.voiceAssignment == .currentVoiceOnly
                case let .spanner(spanner): spanner.hairpin?.voiceAssignment == .currentVoiceOnly
                default: false
                }
            }
        }
    }

    /// One rewritten bar's commands, in the order they apply: `CreateVoice` for each voice the bar lacks, up to the
    /// highest one a write targets (voices are an array, so only the next index can be created); the writes; then
    /// `RemoveVoice` from the last voice down to `voiceCountAfter`. Voice 0 is never removed.
    private func barCommands(
        _ writes: [RevoiceVoiceWrite], voiceCountAfter: Int, voiceCount: Int, measureIndex: Int,
    ) -> [any EditCommand] {
        var commands: [any EditCommand] = []
        let highestWritten = writes.map(\.voiceIndex).max() ?? -1
        let countAfterCreating = max(voiceCount, min(voiceCountAfter, highestWritten + 1))
        for voiceIndex in voiceCount ..< countAfterCreating {
            commands.append(CreateVoice(staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex))
        }
        for write in writes.sorted(by: { $0.voiceIndex < $1.voiceIndex }) {
            commands.append(ReplaceVoiceElements(
                staff: staff, measureIndex: measureIndex, voiceIndex: write.voiceIndex,
                slots: write.slots, tupletSlots: write.tupletSlots,
            ))
        }
        for voiceIndex in stride(from: countAfterCreating - 1, through: max(1, voiceCountAfter), by: -1) {
            commands.append(RemoveVoice(staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex))
        }
        return commands
    }
}
