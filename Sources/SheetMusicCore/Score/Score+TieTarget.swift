import Foundation

public extension Score {
    /// Find the next note in the same voice that could serve as the
    /// receiving end of a tie from `noteID`. Walks forward from the
    /// note's element index, skipping non-chord elements, and returns
    /// the first chord that contains a note of identical pitch.
    /// Returns `nil` when no such target exists in the same measure.
    ///
    /// Currently confined to the same measure; cross-measure ties
    /// require additional plumbing (selecting which staff / voice to
    /// continue into and skipping clef / barline boundaries) that
    /// isn't needed for the current arrow-key + `+` toggle UX.
    func nextTieTarget(after noteID: NoteID) -> NoteID? {
        guard let source = self[noteID] else { return nil }
        guard staves.indices.contains(noteID.staffIndex) else {
            return nil
        }
        let measures = staves[noteID.staffIndex].measures
        guard measures.indices.contains(noteID.measureIndex) else {
            return nil
        }
        let voices = measures[noteID.measureIndex].voices
        guard voices.indices.contains(noteID.voiceIndex) else {
            return nil
        }
        let elements = voices[noteID.voiceIndex].elements
        let start = noteID.elementIndex + 1
        guard start < elements.count else { return nil }
        for idx in start..<elements.count {
            switch elements[idx] {
            case .chord(let nextChord):
                guard let matchIdx = nextChord.notes.firstIndex(
                    where: { $0.pitch == source.pitch })
                else { return nil }
                return NoteID(
                    staffIndex: noteID.staffIndex,
                    measureIndex: noteID.measureIndex,
                    voiceIndex: noteID.voiceIndex,
                    elementIndex: idx,
                    noteIndexInChord: matchIdx)
            case .rest:
                // A rest between source and a same-pitch note breaks
                // the tie chain — they're no longer "adjacent".
                return nil
            default:
                continue
            }
        }
        return nil
    }
}
