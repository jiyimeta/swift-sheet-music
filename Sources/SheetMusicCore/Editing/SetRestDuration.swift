import SheetMusicFoundation

/// Change the duration of a rest with the same MuseScore-equivalent
/// rebalancing rules as `SetChordDuration`. Shortening fills the
/// leftover with beat-aligned rests; lengthening consumes following
/// chord/rest elements (and surfaces overshoot of a chord as a
/// tied chain of that chord's clones, preserving its pitch).
///
/// Inside a tuplet `duration` is the WRITTEN length, as for `SetChordDuration` — see `TupletDurationChange`.
///
/// Identical out-of-scope behavior to `SetChordDuration`:
/// - rest is inside a nested tuplet, or asks for more time than its tuplet has left
/// - lengthening crosses the measure boundary
/// - lengthening consumes past a non-timed element
/// - lengthening overlaps a downstream tuplet
///
/// Inverse is a `ReplaceVoiceElements` carrying the pre-edit
/// `elements` + `tuplets`.
public struct SetRestDuration: EditCommand {
    public let location: VoiceElementID
    public let duration: NoteDuration

    public init(at location: VoiceElementID, duration: NoteDuration) {
        self.location = location
        self.duration = duration
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    // swiftlint:disable:next function_body_length
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let voice = DurationChangeAlgorithm
            .voice(in: score, at: location),
            voice.elements.indices.contains(location.elementIndex)
        else {
            throw Self.refused(.targetNotFound(location))
        }
        guard case var .chord(rest) = voice.elements[location.elementIndex],
              rest.notes.isEmpty
        else {
            throw Self.refused(.wrongElementKind(at: location, expected: .rest))
        }
        let division = score.division
        if let inTuplet = try TupletDurationChange.compute(
            in: voice, atIdx: location.elementIndex, mutatedTarget: .chord(rest), written: duration,
            division: division, baseLocation: location, operation: "SetRestDuration", ids: &ids,
        ) {
            return try ReplaceVoiceElements(
                staff: location.staff, measureIndex: location.measureIndex, voiceIndex: location.voiceIndex,
                elements: inTuplet.elements, tuplets: inTuplet.tuplets,
            ).apply(to: &score, ids: &ids)
        }
        let measureDuration = score
            .effectiveMeasureDurations(
                partIndex: location.staff.partIndex,
                staffIndex: location.staff.staffIndexInPart,
            )[location.measureIndex]
        let srcTicks = rest.duration
            .resolved(in: measureDuration)
            .ticks(division: division)
        let dstTicks = duration
            .resolved(in: measureDuration)
            .ticks(division: division)
        if srcTicks == dstTicks {
            return SetRestDuration(at: location, duration: duration)
        }
        let targetRtick = DurationChangeAlgorithm.tickOffset(
            in: voice,
            ofElementAt: location.elementIndex,
            division: division,
        )
        rest.duration = duration
        let (newElements, newTuplets) = try DurationChangeAlgorithm
            .compute(
                in: voice,
                atIdx: location.elementIndex,
                mutatedTarget: .chord(rest),
                srcTicks: srcTicks,
                dstTicks: dstTicks,
                targetRtick: targetRtick,
                division: division,
                baseLocation: location,
                operation: "SetRestDuration",
                targetEID: voice.elements.eid(at: location.elementIndex), ids: &ids,
            )
        let replace = ReplaceVoiceElements(
            staff: location.staff,
            measureIndex: location.measureIndex,
            voiceIndex: location.voiceIndex,
            elements: newElements,
            tuplets: newTuplets,
        )
        return try replace.apply(to: &score, ids: &ids)
    }
}
