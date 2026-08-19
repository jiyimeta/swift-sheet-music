import SheetMusicFoundation

/// Change the duration of a chord, mirroring MuseScore's
/// `Score::changeCRlen` (`engraving/editing/cmd.cpp:1692`):
///
/// **Shorten**: replace the chord's duration; the leftover time
/// becomes a rest (or a sequence of standard rests when the
/// remainder isn't itself a power-of-two duration). The rest
/// pieces are aligned to natural beat boundaries.
///
/// **Lengthen**: walk forward in the same voice and consume
/// following chord/rest elements until enough time is freed; the
/// last consumed element may be partially consumed, in which case
/// the leftover becomes either rests (when the consumed element
/// was a rest) or a tied chain of chord clones (when it was a
/// chord — preserving its pitch).
///
/// Out of scope (refused with `invalidEdit`):
/// - the chord is inside a `Tuplet` span
/// - lengthening would cross the measure boundary
/// - lengthening would consume past a non-timed element
///   (clef / key sig / time sig / barline)
/// - lengthening would overlap a tuplet that follows the chord
///
/// The inverse is a `ReplaceVoiceElements` whose payload is the
/// pre-edit `elements` + `tuplets`, so undo is bit-perfect.
public struct SetChordDuration: EditCommand {
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
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let voice = DurationChangeAlgorithm
            .voice(in: score, at: location),
            voice.elements.indices.contains(location.elementIndex)
        else {
            throw SheetMusicError.invalidEdit(
                reason: "SetChordDuration: location \(location) "
                    + "doesn't resolve to a voice element",
            )
        }
        guard case var .chord(chord)
            = voice.elements[location.elementIndex]
        else {
            throw SheetMusicError.invalidEdit(
                reason: "SetChordDuration: element at \(location) "
                    + "is not a chord",
            )
        }
        try DurationChangeAlgorithm.ensureNotInsideTuplet(
            voice: voice,
            elementIdx: location.elementIndex,
            label: "SetChordDuration",
        )
        let division = score.division
        let srcTicks = chord.duration.ticks(division: division)
        let dstTicks = duration.ticks(division: division)
        if srcTicks == dstTicks {
            return SetChordDuration(at: location, duration: duration)
        }
        let targetRtick = DurationChangeAlgorithm.tickOffset(
            in: voice,
            ofElementAt: location.elementIndex,
            division: division,
        )
        chord.duration = duration
        let (newElements, newTuplets) = try DurationChangeAlgorithm
            .compute(
                in: voice,
                atIdx: location.elementIndex,
                mutatedTarget: .chord(chord),
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
