import SheetMusicFoundation

/// Moves a chord or rest to another voice of the same bar at the same tick — MuseScore's "move to voice N".
///
/// The destination span must be rests: this creates the voice if it is the next free index, splits the rest
/// around the span, drops the chord into the slot and leaves a same-length rest behind. Anything else in the span
/// (a note, a tuplet member) is refused rather than overwritten. Grace notes, articulations, lyrics and
/// chord-anchored slurs travel with the chord because the chord value travels whole.
///
/// > Note: This command is sugar over `CreateVoice` + `SplitRest` (× ≤ 2) + `ReplaceVoiceElements` +
/// > `ReplaceVoiceElement`, bundled in a `CompositeEditCommand` so one undo step reverts the whole move.
public struct MoveToVoice: EditCommand {
    public let location: VoiceElementID
    public let destination: VoiceRef

    public init(at location: VoiceElementID, to destination: VoiceRef) {
        self.location = location
        self.destination = destination
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard destination.staff == location.staff, destination.measureIndex == location.measureIndex,
              destination.voiceIndex != location.voiceIndex
        else { throw Self.refused(.voiceMismatch(from: VoiceRef(location), to: destination)) }
        guard let sourceVoice = DurationChangeAlgorithm.voice(in: score, at: location),
              sourceVoice.elements.indices.contains(location.elementIndex),
              case let .chord(chord) = sourceVoice.elements[location.elementIndex]
        else { throw Self.refused(.targetNotFound(location)) }
        try DurationChangeAlgorithm.ensureNotInsideTuplet(
            voice: sourceVoice, at: location, operation: String(describing: Self.self),
        )

        let measureDuration = score.effectiveMeasureDuration(
            at: location.staff, measureIndex: location.measureIndex,
        )
        let division = score.division
        let start = DurationChangeAlgorithm.tickOffset(
            in: sourceVoice, ofElementAt: location.elementIndex, division: division,
        )
        let length = chord.duration.resolved(in: measureDuration).ticks(division: division)

        // Plan against a scratch copy so every step sees the score the previous one produced, then apply the
        // composite to the real score for the inverse.
        var scratch = score
        var steps: [any EditCommand] = []
        if score[voice: destination] == nil {
            let create = CreateVoice(
                staff: destination.staff, measureIndex: destination.measureIndex,
                voiceIndex: destination.voiceIndex,
            )
            _ = try create.apply(to: &scratch)
            steps.append(create)
        }
        try Self.carveSlot(
            start: start, length: length, in: &scratch, destination: destination,
            steps: &steps, measureDuration: measureDuration,
        )
        try steps.append(Self.replaceSlot(
            start: start, length: length, with: chord, in: scratch,
            destination: destination, measureDuration: measureDuration,
        ))
        steps.append(ReplaceVoiceElement(at: location, with: .rest(duration: chord.duration)))
        return try CompositeEditCommand(commands: steps, location: location).apply(to: &score)
    }

    /// Splits the destination voice's rests so that `[start, start + length)` is covered by whole rests only.
    /// Refuses when anything in that span is not a rest outside every tuplet.
    ///
    /// At most two cuts are ever needed — one at each end of the span — and each pass makes at most one, so the
    /// two passes below are exhaustive: after a cut at `start` no rest straddles the span's start, and after one
    /// at `start + length` none straddles its end.
    private static func carveSlot(
        start: Int, length: Int, in scratch: inout Score, destination: VoiceRef,
        steps: inout [any EditCommand], measureDuration: Fraction,
    ) throws {
        for _ in 0 ..< 2 {
            guard let voice = scratch[voice: destination] else { throw refused(.targetNotFound(slot(destination))) }
            guard let cut = try plannedCut(
                start: start, length: length, in: voice, destination: destination,
                measureDuration: measureDuration, division: scratch.division,
            ) else { return }
            _ = try cut.apply(to: &scratch)
            steps.append(cut)
        }
    }

    /// The next `SplitRest` the span needs, or `nil` when the span already falls on rest boundaries. Validates
    /// every timed element it walks past inside the span on the way.
    private static func plannedCut(
        start: Int, length: Int, in voice: Voice, destination: VoiceRef,
        measureDuration: Fraction, division: Int,
    ) throws -> SplitRest? {
        var tick = 0
        for (index, element) in voice.elements.enumerated() {
            guard case let .chord(rest) = element else { continue }
            let ticks = rest.duration.resolved(in: measureDuration).ticks(division: division)
            let end = tick + ticks
            if end > start, tick < start + length {
                let id = slot(destination, elementIndex: index)
                let inTuplet = voice.tuplets.contains { $0.startIndex <= index && index <= $0.endIndex }
                guard rest.notes.isEmpty, !inTuplet else { throw refused(.destinationNotFree(id)) }
                if tick < start { return SplitRest(at: id, tickOffset: start - tick) }
                if end > start + length { return SplitRest(at: id, tickOffset: start + length - tick) }
            }
            tick = end
        }
        return nil
    }

    /// The run of rests covering exactly `[start, start + length)` collapsed into `chord`.
    ///
    /// The run can be several elements — `SplitRest` spells a gap as the aligned rests that tile it — so
    /// collapsing it shortens the element list, and every tuplet after the run has to move left by as much.
    private static func replaceSlot(
        start: Int, length: Int, with chord: Chord, in scratch: Score,
        destination: VoiceRef, measureDuration: Fraction,
    ) throws -> ReplaceVoiceElements {
        guard let voice = scratch[voice: destination] else { throw refused(.targetNotFound(slot(destination))) }
        var tick = 0
        var elements: [VoiceElement] = []
        var collapsed = 0
        var lastCollapsedIndex = 0
        for (index, element) in voice.elements.enumerated() {
            guard case let .chord(rest) = element else {
                elements.append(element)
                continue
            }
            let ticks = rest.duration.resolved(in: measureDuration).ticks(division: scratch.division)
            if tick >= start, tick + ticks <= start + length {
                if collapsed == 0 { elements.append(.chord(chord)) }
                collapsed += 1
                lastCollapsedIndex = index
            } else {
                elements.append(element)
            }
            tick += ticks
        }
        let tuplets = MeasureStructure.shiftTuplets(
            voice.tuplets, by: collapsed > 0 ? -(collapsed - 1) : 0, after: lastCollapsedIndex,
        )
        return ReplaceVoiceElements(
            staff: destination.staff, measureIndex: destination.measureIndex, voiceIndex: destination.voiceIndex,
            elements: elements, tuplets: tuplets,
        )
    }

    private static func slot(_ voice: VoiceRef, elementIndex: Int = 0) -> VoiceElementID {
        VoiceElementID(
            staff: voice.staff, measureIndex: voice.measureIndex,
            voiceIndex: voice.voiceIndex, elementIndex: elementIndex,
        )
    }
}
