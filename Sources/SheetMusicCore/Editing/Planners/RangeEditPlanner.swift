import SheetMusicFoundation

/// The engine behind every range command (spec 2026-09-02 §3.1, "Range commands apply in ascending onset order,
/// re-resolving by tick"): resolves a `VoiceElementRange` once, then walks its targets voice by voice in ascending
/// onset order, building one `CompositeEditCommand` a step at a time against the score the previous step produced.
///
/// Each target is re-found before its step runs by `(staff, measure, voice, onset tick)` in the working score. An
/// onset that no element starts at any more — consumed by a lengthening earlier in the same voice — is skipped.
/// That is what turns `[q q q q] → half` into `[h h]` the way MuseScore does: the second quarter's onset is gone
/// by the time it is reached, so it is not re-timed on top of the half that swallowed it.
///
/// Ticks are sums of stored durations, which are sounding ticks even inside and after a tuplet (`TupletOnsetTests`).
///
/// Per-element commands rewrite ONE voice (`ReplaceVoiceElements`, `ReplaceVoiceElement`, `SetNotePitch`,
/// `AddNoteToChord`), never another voice's element count, so element-order within a voice is the only order the
/// re-resolution has to honor — and `Score.voiceElements(in:)` already yields exactly that.
///
/// A step that throws propagates out of `plan` before anything has touched the caller's score; a command that
/// refuses at apply time is rolled back with everything before it by `CompositeEditCommand.apply`.
enum RangeEditPlanner {
    struct Plan {
        var commands: [any EditCommand]
        /// The first resolved target — what the composite reports as its affected location.
        let location: VoiceElementID
        /// The score every command in `commands` has been applied to, in order. Range commands that need a second
        /// pass (`DeleteRange`'s full-measure collapse) plan it against this.
        var result: Score

        var composite: CompositeEditCommand {
            CompositeEditCommand(commands: commands, location: location)
        }
    }

    /// `nil` when the range resolves to nothing or every step produced nothing — the planner's "restating is nil".
    static func plan(
        over range: VoiceElementRange, in score: Score,
        step: (_ target: VoiceElementID, _ working: Score) throws -> [any EditCommand],
    ) throws -> Plan? {
        let targets = score.voiceElements(in: range)
        guard let first = targets.first else { return nil }
        var plan = Plan(commands: [], location: first, result: score)
        for target in targets {
            guard let onset = score.onset(of: target),
                  let index = plan.result.timedElementIndex(startingAt: onset.tick, in: VoiceRef(target))
            else { continue }
            for command in try step(target.withElementIndex(index), plan.result) {
                _ = try command.apply(to: &plan.result)
                plan.commands.append(command)
            }
        }
        return plan.commands.isEmpty ? nil : plan
    }

    /// Whether pitch edits mean anything on `staff`: a drum kit or a percussion staff has no key to be in or out
    /// of. Same test `MeasureAccidentals.renotationCommands(in:measureRange:)` applies.
    static func isPitched(_ staff: StaffAddress, in score: Score) -> Bool {
        guard let part = score.part(at: staff), let target = score[staff] else { return false }
        return !part.instrument.useDrumset && target.group != "percussion"
    }

    /// The tie chains through the chord at `id` that no earlier target has claimed, and marks them claimed. A chain
    /// is one sounding note written across several slots, so a pitch edit addresses it whole — even the members
    /// outside the range — and addresses it once, whichever member the walk reaches first.
    static func unvisitedTieChains(
        of id: VoiceElementID, in score: Score, visited: inout Set<NoteID>,
    ) -> [[NoteID]] {
        guard case let .chord(chord)? = score[id] else { return [] }
        var chains: [[NoteID]] = []
        for noteIndex in chord.notes.indices {
            let noteID = NoteID(
                staff: id.staff, measureIndex: id.measureIndex, voiceIndex: id.voiceIndex,
                elementIndex: id.elementIndex, noteIndexInChord: noteIndex,
            )
            let chain = TiePlanner.tieChain(containing: noteID, in: score)
            guard !chain.isEmpty, visited.isDisjoint(with: chain) else { continue }
            visited.formUnion(chain)
            chains.append(chain)
        }
        return chains
    }
}

extension Score {
    /// Index of the chord or rest of `voice` that STARTS at `tick`, or `nil` when none does — because the tick lies
    /// inside an element, past the voice's end, or the voice does not exist.
    func timedElementIndex(startingAt tick: Int, in voice: VoiceRef) -> Int? {
        guard let elements = self[voice: voice]?.elements else { return nil }
        let measureDuration = effectiveMeasureDuration(at: voice.staff, measureIndex: voice.measureIndex)
        var cursor = 0
        for (index, element) in elements.enumerated() {
            guard case let .chord(timed) = element else { continue }
            if cursor == tick { return index }
            if cursor > tick { return nil }
            cursor += timed.duration.resolved(in: measureDuration).ticks(division: division)
        }
        return nil
    }
}
