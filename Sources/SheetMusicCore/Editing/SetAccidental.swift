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
        let respelled = Self.respelled(oldNote, with: accidental, at: location, in: score)
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

    /// `PitchSpelling.respelled(from:with:)` performed on the note as the STAFF reads it, handed back in concert
    /// values. Identical to calling it directly on a staff that does not transpose.
    ///
    /// The distinction is the letter the respelling preserves, and on a transposing staff the two letters are
    /// different ones. ♯ means "sharpen the note on the page": concert B♭ on a B♭ clarinet is a written C, so ♯
    /// has to produce a written C♯ (concert B♮). Preserving the CONCERT letter instead produces a B♯, which that
    /// staff engraves as C𝄪 — a double sharp a whole tone above what the user tapped ♯ on.
    ///
    /// `accidental: nil` still leaves pitch and tpc alone (the caller only wants the glyph cleared), so the
    /// detour is a no-op there too.
    private static func respelled(
        _ note: Note, with accidental: Accidental?, at location: NoteID, in score: Score,
    ) -> (pitch: Int, tpc: Int) {
        let offsets = score.writtenSpaceOffsets(staff: location.staff, measureIndex: location.measureIndex)
        guard offsets.pitch != 0 || offsets.fifths != 0 else {
            return PitchSpelling.respelled(from: note, with: accidental)
        }
        var asRead = note
        asRead.pitch += offsets.pitch
        asRead.tpc += offsets.fifths
        let written = PitchSpelling.respelled(from: asRead, with: accidental)
        return (written.pitch - offsets.pitch, written.tpc - offsets.fifths)
    }
}
