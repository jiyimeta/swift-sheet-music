import Foundation

/// Path-based identity of a `Rest` inside a `Score`.
///
/// A `RestID` is a value-based pointer: a 4-tuple of indices that
/// resolves to `Score.staves[staff].measures[measure]
/// .voices[voice].elements[element]` where the element must be
/// `.rest`.
///
/// IDs are stable only for an immutable `Score`. Mutating the
/// underlying score may invalidate existing IDs.
public struct RestID: Hashable, Sendable {
    public let staffIndex: Int
    public let measureIndex: Int
    public let voiceIndex: Int
    /// Index into `Voice.elements`. The element must be `.rest`.
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
}

extension Score {
    /// Resolves a `RestID` to its `Rest`, or `nil` if the path is out
    /// of range or does not land on a rest element.
    public subscript(restID: RestID) -> Rest? {
        guard staves.indices.contains(restID.staffIndex) else { return nil }
        let measures = staves[restID.staffIndex].measures
        guard measures.indices.contains(restID.measureIndex) else { return nil }
        let voices = measures[restID.measureIndex].voices
        guard voices.indices.contains(restID.voiceIndex) else { return nil }
        let elements = voices[restID.voiceIndex].elements
        guard elements.indices.contains(restID.elementIndex) else { return nil }
        guard case let .rest(rest) = elements[restID.elementIndex] else { return nil }
        return rest
    }
}
