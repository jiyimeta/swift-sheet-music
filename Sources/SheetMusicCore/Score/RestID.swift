import Foundation

/// Path-based identity of a rest inside a `Score`.
public struct RestID: Hashable, Sendable {
    public let staff: StaffAddress
    public let measureIndex: Int
    public let voiceIndex: Int
    public let elementIndex: Int

    public init(
        staff: StaffAddress,
        measureIndex: Int,
        voiceIndex: Int,
        elementIndex: Int
    ) {
        self.staff = staff
        self.measureIndex = measureIndex
        self.voiceIndex = voiceIndex
        self.elementIndex = elementIndex
    }
}

extension Score {
    public subscript(restID: RestID) -> Chord? {
        guard let staff = self[restID.staff] else { return nil }
        guard staff.measures.indices.contains(restID.measureIndex) else { return nil }
        let voices = staff.measures[restID.measureIndex].voices
        guard voices.indices.contains(restID.voiceIndex) else { return nil }
        let elements = voices[restID.voiceIndex].elements
        guard elements.indices.contains(restID.elementIndex) else { return nil }
        guard case let .chord(chord) = elements[restID.elementIndex],
              chord.notes.isEmpty
        else { return nil }
        return chord
    }
}
