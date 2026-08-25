import SheetMusicFoundation

/// Apply (or clear) an explicit accidental on a note. Mirrors the
/// accidental tool buttons in MuseScore's toolbar: clicking ♯ on a
/// natural C respells it as C♯ (pitch +1), clicking ♭ makes it C♭
/// (pitch −1), clicking ♮ on a D♭ makes it D natural, etc. The
/// diatonic letter is preserved across the change.
///
/// Passing `accidental: nil` clears the displayed glyph but leaves
/// pitch and TPC alone — useful for letting a note revert to the
/// reading implied by the active key signature.
///
/// Inverse is a `SetNotePitch` that carries the original pitch,
/// TPC, and accidental, so undo restores all three verbatim even
/// when the user cycled through several accidentals in a row.
///
/// > Note: This command is sugar over
/// > `PitchSpelling.respelled(from:with:)` + `SetNotePitch`. It
/// > exists to give the operation a domain-meaningful name and to
/// > pair the respelling with the pitch / TPC update in one
/// > intent; callers can equally construct the equivalent
/// > `SetNotePitch` directly. See `docs/edit-commands.md` for the
/// > policy.
public struct SetAccidental: EditCommand {
    public let location: NoteID
    public let accidental: Accidental?

    public init(at location: NoteID, accidental: Accidental?) {
        self.location = location
        self.accidental = accidental
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(location)
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let oldNote = score[location] else {
            throw Self.refused(.noteNotFound(location))
        }
        let veID = VoiceElementID(location)
        guard case var .chord(chord) = score[veID] else {
            throw Self.refused(.wrongElementKind(at: veID, expected: .chord))
        }
        let respelled = PitchSpelling.respelled(
            from: oldNote, with: accidental,
        )
        var note = chord.notes[location.noteIndexInChord]
        note.pitch = respelled.pitch
        note.tpc = respelled.tpc
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
