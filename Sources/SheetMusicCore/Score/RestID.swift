import Foundation

/// Path-based identity of a rest inside a `Score`. A rest is a
/// `Chord` whose `notes` array is empty (see the `VoiceElement`
/// type doc); `RestID` is the selection-side handle for clicking
/// on a rest glyph, distinct from `NoteID` which addresses a
/// specific note within a chord.
///
/// IDs are stable only for an immutable `Score`. Mutating the
/// underlying score may invalidate existing IDs.
public struct RestID: Hashable, Sendable {
    public let staffIndex: Int
    public let measureIndex: Int
    public let voiceIndex: Int
    /// Index into `Voice.elements`. The element must be `.chord`
    /// with `notes.isEmpty == true`.
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
    /// Resolves a `RestID` to the rest's underlying `Chord` (always
    /// `notes.isEmpty == true`), or `nil` if the path is out of
    /// range or does not land on a rest element.
    public subscript(restID: RestID) -> Chord? {
        guard staves.indices.contains(restID.staffIndex) else { return nil }
        let measures = staves[restID.staffIndex].measures
        guard measures.indices.contains(restID.measureIndex) else { return nil }
        let voices = measures[restID.measureIndex].voices
        guard voices.indices.contains(restID.voiceIndex) else { return nil }
        let elements = voices[restID.voiceIndex].elements
        guard elements.indices.contains(restID.elementIndex) else { return nil }
        guard case let .chord(chord) = elements[restID.elementIndex],
              chord.notes.isEmpty
        else { return nil }
        return chord
    }
}
