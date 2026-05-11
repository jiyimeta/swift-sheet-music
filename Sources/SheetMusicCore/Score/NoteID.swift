import Foundation

/// Path-based identity of a `Note` inside a `Score`. Walks
/// `score.parts[staff.partIndex].staves[staff.staffIndexInPart]
/// .measures[measure].voices[voice].elements[element]` (must be `.chord`)
/// and then into `Chord.notes[noteIndexInChord]`.
public struct NoteID: Hashable, Sendable {
    public let staff: StaffAddress
    public let measureIndex: Int
    public let voiceIndex: Int
    public let elementIndex: Int
    public let noteIndexInChord: Int

    public init(
        staff: StaffAddress,
        measureIndex: Int,
        voiceIndex: Int,
        elementIndex: Int,
        noteIndexInChord: Int,
    ) {
        self.staff = staff
        self.measureIndex = measureIndex
        self.voiceIndex = voiceIndex
        self.elementIndex = elementIndex
        self.noteIndexInChord = noteIndexInChord
    }
}

extension Score {
    public subscript(noteID: NoteID) -> Note? {
        guard let staff = self[noteID.staff] else { return nil }
        guard staff.measures.indices.contains(noteID.measureIndex) else { return nil }
        let voices = staff.measures[noteID.measureIndex].voices
        guard voices.indices.contains(noteID.voiceIndex) else { return nil }
        let elements = voices[noteID.voiceIndex].elements
        guard elements.indices.contains(noteID.elementIndex) else { return nil }
        guard case let .chord(chord) = elements[noteID.elementIndex] else { return nil }
        guard chord.notes.indices.contains(noteID.noteIndexInChord) else { return nil }
        return chord.notes[noteID.noteIndexInChord]
    }
}
