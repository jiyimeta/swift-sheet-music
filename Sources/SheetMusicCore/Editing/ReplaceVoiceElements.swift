import Foundation

/// Replace a voice's `elements` (and `tuplets`) wholesale at a given
/// staff / measure / voice location. Used as the inverse of any
/// command whose effect spans more than one element (e.g.
/// `SetChordDuration` lengthening across following elements).
///
/// The inverse is another `ReplaceVoiceElements` carrying the prior
/// values, so apply / undo / redo all round-trip through the same
/// command type.
public struct ReplaceVoiceElements: EditCommand {
    public let staffIndex: Int
    public let measureIndex: Int
    public let voiceIndex: Int
    public let elements: [VoiceElement]
    public let tuplets: [Tuplet]

    public init(
        staffIndex: Int,
        measureIndex: Int,
        voiceIndex: Int,
        elements: [VoiceElement],
        tuplets: [Tuplet] = []
    ) {
        self.staffIndex = staffIndex
        self.measureIndex = measureIndex
        self.voiceIndex = voiceIndex
        self.elements = elements
        self.tuplets = tuplets
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staffIndex: staffIndex,
            measureIndex: measureIndex,
            voiceIndex: voiceIndex,
            elementIndex: 0)
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard score.staves.indices.contains(staffIndex) else {
            throw SheetMusicError.invalidEdit(
                reason: "ReplaceVoiceElements: staff \(staffIndex) "
                    + "out of range")
        }
        guard score.staves[staffIndex].measures
            .indices.contains(measureIndex) else {
            throw SheetMusicError.invalidEdit(
                reason: "ReplaceVoiceElements: measure "
                    + "\(measureIndex) out of range")
        }
        guard score.staves[staffIndex]
            .measures[measureIndex].voices
            .indices.contains(voiceIndex) else {
            throw SheetMusicError.invalidEdit(
                reason: "ReplaceVoiceElements: voice "
                    + "\(voiceIndex) out of range")
        }
        let priorVoice = score.staves[staffIndex]
            .measures[measureIndex].voices[voiceIndex]
        score.staves[staffIndex]
            .measures[measureIndex]
            .voices[voiceIndex] = Voice(
                elements: elements, tuplets: tuplets)
        return ReplaceVoiceElements(
            staffIndex: staffIndex,
            measureIndex: measureIndex,
            voiceIndex: voiceIndex,
            elements: priorVoice.elements,
            tuplets: priorVoice.tuplets)
    }
}
