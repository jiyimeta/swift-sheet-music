import SheetMusicFoundation

/// Split the rest at `location` into two beat-aligned runs, with a slot boundary `tickOffset` ticks into it.
///
/// The column caret (drum note entry's §5.4) lands on a TICK, not on an element, so a caret sitting inside a
/// half rest has nothing to write into: every write command in this package targets a slot. This makes the slot.
///
/// Both halves are spelled the way MuseScore spells a gap — `DurationChangeAlgorithm.alignedRests`, largest
/// power-of-two duration that both fits and lands on its own boundary — so splitting an eighth into a half rest
/// produces `eighth + eighth + quarter`, not `eighth + dotted quarter`.
///
/// `.measure` is resolved against the bar before the arithmetic: a full-measure rest is "however long this bar
/// is", and asking it for ticks without resolving traps.
///
/// The inverse is a whole-voice `ReplaceVoiceElements`, which restores the rest's original SPELLING — a
/// `.measure` rest comes back as `.measure`, not as a same-length whole rest — and puts back the tuplet list
/// verbatim.
public struct SplitRest: EditCommand {
    public let location: VoiceElementID
    public let tickOffset: Int

    public init(at location: VoiceElementID, tickOffset: Int) {
        self.location = location
        self.tickOffset = tickOffset
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let voice = DurationChangeAlgorithm.voice(in: score, at: location) else {
            throw Self.refused(.targetNotFound(location))
        }
        guard voice.elements.indices.contains(location.elementIndex),
              case let .chord(rest) = voice.elements[location.elementIndex],
              rest.notes.isEmpty
        else {
            throw Self.refused(.wrongElementKind(at: location, expected: .rest))
        }
        try DurationChangeAlgorithm.ensureNotInsideTuplet(
            voice: voice, at: location, operation: String(describing: Self.self),
        )

        let measureDuration = score.effectiveMeasureDuration(
            at: location.staff, measureIndex: location.measureIndex,
        )
        let totalTicks = rest.duration.resolved(in: measureDuration).ticks(division: score.division)
        guard tickOffset > 0, tickOffset < totalTicks else {
            throw Self.refused(.insufficientRoom(neededTicks: tickOffset, availableTicks: totalTicks))
        }

        let rtickStart = DurationChangeAlgorithm.tickOffset(
            in: voice, ofElementAt: location.elementIndex, division: score.division,
        )
        let head = DurationChangeAlgorithm.alignedRests(
            forTicks: tickOffset, rtickStart: rtickStart, division: score.division,
        )
        let tail = DurationChangeAlgorithm.alignedRests(
            forTicks: totalTicks - tickOffset, rtickStart: rtickStart + tickOffset,
            division: score.division,
        )

        var elements = voice.elements
        elements.replaceSubrange(location.elementIndex ... location.elementIndex, with: head + tail)
        // One element became `head + tail`, so every tuplet that starts after it has to move right by the
        // difference or it would keep pointing at the elements the splice pushed along.
        let tuplets = MeasureStructure.shiftTuplets(
            voice.tuplets, by: head.count + tail.count - 1, after: location.elementIndex,
        )
        let write = ReplaceVoiceElements(
            staff: location.staff,
            measureIndex: location.measureIndex,
            voiceIndex: location.voiceIndex,
            elements: elements,
            tuplets: tuplets,
        )
        // `ReplaceVoiceElements` hands back the prior voice as its own inverse, which is exactly what undo
        // needs here — the rest as it was spelled, and the tuplet list untouched.
        return try write.apply(to: &score)
    }
}
