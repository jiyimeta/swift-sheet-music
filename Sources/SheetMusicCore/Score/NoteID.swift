import Foundation

/// Path-based identity of a `Note` inside a `Score`.
///
/// A `NoteID` is a value-based pointer: a 5-tuple of indices that walks
/// `Score.staves[staff].measures[measure].voices[voice].elements[element]`
/// (where the element must resolve to a `.chord`) and then into
/// `Chord.notes[noteIndexInChord]`.
///
/// IDs are stable only for an immutable `Score`. Mutating the underlying
/// score (inserting/removing measures, reordering voices, etc.) may
/// invalidate existing IDs.
public struct NoteID: Hashable, Sendable {
    public let staffIndex: Int
    public let measureIndex: Int
    public let voiceIndex: Int
    /// Index into `Voice.elements`. The element at this index must be a
    /// `.chord`; otherwise the ID does not resolve to a note.
    public let elementIndex: Int
    public let noteIndexInChord: Int

    public init(
        staffIndex: Int,
        measureIndex: Int,
        voiceIndex: Int,
        elementIndex: Int,
        noteIndexInChord: Int
    ) {
        self.staffIndex = staffIndex
        self.measureIndex = measureIndex
        self.voiceIndex = voiceIndex
        self.elementIndex = elementIndex
        self.noteIndexInChord = noteIndexInChord
    }
}

extension Score {
    /// Resolves a `NoteID` to its `Note`, or `nil` if the path is out of
    /// range or does not land on a chord note.
    public subscript(noteID: NoteID) -> Note? {
        guard staves.indices.contains(noteID.staffIndex) else { return nil }
        let measures = staves[noteID.staffIndex].measures
        guard measures.indices.contains(noteID.measureIndex) else { return nil }
        let voices = measures[noteID.measureIndex].voices
        guard voices.indices.contains(noteID.voiceIndex) else { return nil }
        let elements = voices[noteID.voiceIndex].elements
        guard elements.indices.contains(noteID.elementIndex) else { return nil }
        guard case let .chord(chord) = elements[noteID.elementIndex] else { return nil }
        guard chord.notes.indices.contains(noteID.noteIndexInChord) else { return nil }
        return chord.notes[noteID.noteIndexInChord]
    }
}
