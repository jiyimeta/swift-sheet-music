import Foundation

/// Retunes a note (changes its MIDI `pitch`, `tpc`, and the
/// accidental override the layout renders).
///
/// Used for arrow-key transpose and for replacing one note within a
/// chord. The inverse is another `SetNotePitch` carrying the old
/// values, so undo restores both the pitch and the accidental
/// glyph that was visible before.
public struct SetNotePitch: EditCommand {
    public let location: NoteID
    public let pitch: Int
    public let tpc: Int
    /// Accidental glyph to display on the note. Pass `nil` to
    /// suppress (the note matches the key sig at this beat).
    /// Computed via `PitchSpelling.displayedAccidental(forTpc:in:)`
    /// for arrow-key shifts.
    public let accidental: Accidental?

    public init(
        at location: NoteID,
        pitch: Int,
        tpc: Int,
        accidental: Accidental? = nil,
    ) {
        self.location = location
        self.pitch = pitch
        self.tpc = tpc
        self.accidental = accidental
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(location)
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let oldNote = score[location] else {
            throw SheetMusicError.invalidEdit(
                reason: "SetNotePitch: no note at \(location)",
            )
        }
        let veID = VoiceElementID(location)
        guard case var .chord(chord) = score[veID] else {
            throw SheetMusicError.invalidEdit(
                reason: "SetNotePitch: element at \(veID) is not a chord",
            )
        }
        var note = chord.notes[location.noteIndexInChord]
        note.pitch = pitch
        note.tpc = tpc
        note.accidental = accidental
        chord.notes[location.noteIndexInChord] = note
        score[veID] = .chord(chord)
        return SetNotePitch(
            at: location,
            pitch: oldNote.pitch,
            tpc: oldNote.tpc,
            accidental: oldNote.accidental,
        )
    }
}
