import Foundation

/// Retunes a note (changes its MIDI `pitch` and `tpc`) without
/// affecting its accidental, ties, or other notehead metadata.
///
/// Used for arrow-key transpose and for replacing one note within a
/// chord. The inverse is another `SetNotePitch` carrying the old
/// values.
public struct SetNotePitch: EditCommand {
    public let location: NoteID
    public let pitch: Int
    public let tpc: Int

    public init(at location: NoteID, pitch: Int, tpc: Int) {
        self.location = location
        self.pitch = pitch
        self.tpc = tpc
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let oldNote = score[location] else {
            throw SheetMusicError.invalidEdit(
                reason: "SetNotePitch: no note at \(location)")
        }
        let veID = VoiceElementID(location)
        guard case var .chord(chord) = score[veID] else {
            throw SheetMusicError.invalidEdit(
                reason: "SetNotePitch: element at \(veID) is not a chord")
        }
        var note = chord.notes[location.noteIndexInChord]
        note.pitch = pitch
        note.tpc = tpc
        chord.notes[location.noteIndexInChord] = note
        score[veID] = .chord(chord)
        return SetNotePitch(at: location,
                            pitch: oldNote.pitch,
                            tpc: oldNote.tpc)
    }
}
