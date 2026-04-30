import Foundation

/// Path-based identity of a `VoiceElement` inside a `Score`.
///
/// Walks `Score.staves[staff].measures[measure].voices[voice]
/// .elements[element]`. Unlike `RestID` / `NoteID`, this does NOT
/// constrain the element kind — any `VoiceElement` is addressable.
///
/// IDs are stable only for an immutable `Score`; mutating the
/// underlying score may invalidate existing IDs.
public struct VoiceElementID: Hashable, Sendable {
    public let staffIndex: Int
    public let measureIndex: Int
    public let voiceIndex: Int
    public let elementIndex: Int

    public init(
        staffIndex: Int,
        measureIndex: Int,
        voiceIndex: Int,
        elementIndex: Int
    ) {
        self.staffIndex = staffIndex
        self.measureIndex = measureIndex
        self.voiceIndex = voiceIndex
        self.elementIndex = elementIndex
    }

    public init(_ id: RestID) {
        self.init(
            staffIndex: id.staffIndex,
            measureIndex: id.measureIndex,
            voiceIndex: id.voiceIndex,
            elementIndex: id.elementIndex)
    }

    public init(_ id: NoteID) {
        self.init(
            staffIndex: id.staffIndex,
            measureIndex: id.measureIndex,
            voiceIndex: id.voiceIndex,
            elementIndex: id.elementIndex)
    }
}

extension Score {
    /// Resolves a `VoiceElementID` to its element, or `nil` if the
    /// path is out of range.
    public subscript(id: VoiceElementID) -> VoiceElement? {
        get {
            guard staves.indices.contains(id.staffIndex) else { return nil }
            let measures = staves[id.staffIndex].measures
            guard measures.indices.contains(id.measureIndex) else { return nil }
            let voices = measures[id.measureIndex].voices
            guard voices.indices.contains(id.voiceIndex) else { return nil }
            let elements = voices[id.voiceIndex].elements
            guard elements.indices.contains(id.elementIndex) else { return nil }
            return elements[id.elementIndex]
        }
        set {
            guard let newValue,
                  staves.indices.contains(id.staffIndex),
                  staves[id.staffIndex].measures.indices.contains(id.measureIndex),
                  staves[id.staffIndex].measures[id.measureIndex]
                      .voices.indices.contains(id.voiceIndex),
                  staves[id.staffIndex].measures[id.measureIndex]
                      .voices[id.voiceIndex].elements.indices
                          .contains(id.elementIndex)
            else { return }
            staves[id.staffIndex]
                .measures[id.measureIndex]
                .voices[id.voiceIndex]
                .elements[id.elementIndex] = newValue
        }
    }
}
