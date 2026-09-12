import SheetMusicFoundation

/// Writes one note's sounding flag — MuseScore's `<play>`, which round-trips through MSCX and is honored by the
/// MIDI renderer (`MidiRenderer+*`: a note with `play == false` emits nothing, and tremolo, glissando and bend
/// realizations skip it too). Engraving is unaffected: the notehead is still drawn.
///
/// The mirror image of `SetNoteVisible`, which hides the ink and leaves the sound. Neither derives the other —
/// `ElementProperties.visible`'s doc comment states that sounding is governed here, not there.
///
/// > Note: This command is sugar over `ReplaceVoiceElement`. It exists to give the operation a domain-meaningful
/// > name and to centralise the small bit of validation it performs; callers can equally well construct the
/// > equivalent primitive directly. See `docs/edit-commands.md` for the policy.
public struct SetNotePlay: EditCommand {
    public let location: NoteID
    public let play: Bool

    public init(at location: NoteID, play: Bool) {
        self.location = location
        self.play = play
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(location)
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let oldNote = score[location] else {
            throw Self.refused(.noteNotFound(location))
        }
        let veID = VoiceElementID(location)
        guard case var .chord(chord) = score[veID] else {
            throw Self.refused(.wrongElementKind(at: veID, expected: .chord))
        }
        chord.notes.updateNote(at: location.noteIndexInChord) { $0.play = play }
        score[veID] = .chord(chord)
        return SetNotePlay(at: location, play: oldNote.play)
    }
}
