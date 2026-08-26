import SheetMusicFoundation

/// Replace a voice's `elements` (and `tuplets`) wholesale at a given
/// staff / measure / voice location. Used as the inverse of any
/// command whose effect spans more than one element (e.g.
/// `SetChordDuration` lengthening across following elements).
///
/// The inverse is another `ReplaceVoiceElements` carrying the prior
/// values, so apply / undo / redo all round-trip through the same
/// command type.
public struct ReplaceVoiceElements: EditCommand {
    public let staff: StaffAddress
    public let measureIndex: Int
    public let voiceIndex: Int
    public let elements: [VoiceElement]
    public let tuplets: [Tuplet]

    public init(
        staff: StaffAddress,
        measureIndex: Int,
        voiceIndex: Int,
        elements: [VoiceElement],
        tuplets: [Tuplet] = [],
    ) {
        self.staff = staff
        self.measureIndex = measureIndex
        self.voiceIndex = voiceIndex
        self.elements = elements
        self.tuplets = tuplets
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: staff,
            measureIndex: measureIndex,
            voiceIndex: voiceIndex,
            elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard score.parts.indices.contains(staff.partIndex),
              score.parts[staff.partIndex].staves.indices
                  .contains(staff.staffIndexInPart)
        else {
            throw Self.refused(.staffNotFound(staff))
        }
        let p = staff.partIndex
        let s = staff.staffIndexInPart
        guard score.parts[p].staves[s].measures
            .indices.contains(measureIndex)
        else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        guard score.parts[p].staves[s]
            .measures[measureIndex].voices
            .indices.contains(voiceIndex)
        else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        let priorVoice = score.parts[p].staves[s]
            .measures[measureIndex].voices[voiceIndex]
        score.parts[p].staves[s]
            .measures[measureIndex]
            .voices[voiceIndex] = Voice(
                elements: elements, tuplets: tuplets,
            )
        return ReplaceVoiceElements(
            staff: staff,
            measureIndex: measureIndex,
            voiceIndex: voiceIndex,
            elements: priorVoice.elements,
            tuplets: priorVoice.tuplets,
        )
    }
}
