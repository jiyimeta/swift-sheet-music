import Foundation

public struct VoiceElementID: Hashable, Sendable {
    public let staff: StaffAddress
    public let measureIndex: Int
    public let voiceIndex: Int
    public let elementIndex: Int

    public init(
        staff: StaffAddress,
        measureIndex: Int,
        voiceIndex: Int,
        elementIndex: Int,
    ) {
        self.staff = staff
        self.measureIndex = measureIndex
        self.voiceIndex = voiceIndex
        self.elementIndex = elementIndex
    }

    public init(_ id: RestID) {
        self.init(
            staff: id.staff,
            measureIndex: id.measureIndex,
            voiceIndex: id.voiceIndex,
            elementIndex: id.elementIndex,
        )
    }

    public init(_ id: NoteID) {
        self.init(
            staff: id.staff,
            measureIndex: id.measureIndex,
            voiceIndex: id.voiceIndex,
            elementIndex: id.elementIndex,
        )
    }
}

extension Score {
    public subscript(id: VoiceElementID) -> VoiceElement? {
        get {
            guard let staff = self[id.staff],
                  staff.measures.indices.contains(id.measureIndex)
            else { return nil }
            let voices = staff.measures[id.measureIndex].voices
            guard voices.indices.contains(id.voiceIndex) else { return nil }
            let elements = voices[id.voiceIndex].elements
            guard elements.indices.contains(id.elementIndex) else { return nil }
            return elements[id.elementIndex]
        }
        set {
            guard let newValue,
                  parts.indices.contains(id.staff.partIndex),
                  parts[id.staff.partIndex].staves.indices
                      .contains(id.staff.staffIndexInPart)
            else { return }
            let p = id.staff.partIndex
            let s = id.staff.staffIndexInPart
            guard parts[p].staves[s].measures.indices
                .contains(id.measureIndex),
                parts[p].staves[s].measures[id.measureIndex]
                    .voices.indices.contains(id.voiceIndex),
                    parts[p].staves[s].measures[id.measureIndex]
                        .voices[id.voiceIndex].elements.indices
                        .contains(id.elementIndex)
            else { return }
            parts[p].staves[s]
                .measures[id.measureIndex]
                .voices[id.voiceIndex]
                .elements[id.elementIndex] = newValue
        }
    }
}
