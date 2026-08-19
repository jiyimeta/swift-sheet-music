import SheetMusicFoundation

/// Change the duration of a rest with the same MuseScore-equivalent
/// rebalancing rules as `SetChordDuration`. Shortening fills the
/// leftover with beat-aligned rests; lengthening consumes following
/// chord/rest elements (and surfaces overshoot of a chord as a
/// tied chain of that chord's clones, preserving its pitch).
///
/// Identical out-of-scope behavior to `SetChordDuration`:
/// - rest is inside a tuplet
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
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let voice = DurationChangeAlgorithm
            .voice(in: score, at: location),
            voice.elements.indices.contains(location.elementIndex)
        else {
            throw SheetMusicError.invalidEdit(
                reason: "SetRestDuration: location \(location) "
                    + "doesn't resolve to a voice element",
            )
        }
        guard case var .chord(rest) = voice.elements[location.elementIndex],
              rest.notes.isEmpty
        else {
            throw SheetMusicError.invalidEdit(
                reason: "SetRestDuration: element at \(location) "
                    + "is not a rest (empty chord)",
            )
        }
        try DurationChangeAlgorithm.ensureNotInsideTuplet(
            voice: voice,
            elementIdx: location.elementIndex,
            label: "SetRestDuration",
        )
        let division = score.division
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
            )
        let replace = ReplaceVoiceElements(
            staff: location.staff,
            measureIndex: location.measureIndex,
            voiceIndex: location.voiceIndex,
            elements: newElements,
            tuplets: newTuplets,
        )
        return try replace.apply(to: &score)
    }
}
