import SheetMusicFoundation

/// Shows or hides one notehead — MuseScore's `V` on a note — by writing `Note.visible`. Playback is unaffected
/// (`Note.play` governs sounding).
///
/// Only the note's own flag moves. MuseScore's `V` also hides the note's dots and accidental (the layout already
/// draws ssm's accidental with its note) and, once no visible note remains in the chord, the stem and hook — and
/// the beam once none remains in the beam group (`edit.cpp`, `undoChangeNoteVisibility`). ssm keeps `Note.visible`,
/// `Chord.stemVisible` and `Chord.beamVisible` independent (`Chord.stemVisible` doc), so a host wanting that cascade
/// composes this with `SetStemVisible` / `SetBeamVisible` in one composite rather than have the engine guess.
///
/// > Note: This command is sugar over `ReplaceVoiceElement`. It exists to give the operation a domain-meaningful
/// > name and to centralise the small bit of validation it performs; callers can equally construct the primitive
/// > directly. See `docs/edit-commands.md`.
public struct SetNoteVisible: EditCommand {
    public let location: NoteID
    public let visible: Bool

    public init(at location: NoteID, visible: Bool) {
        self.location = location
        self.visible = visible
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(location)
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let oldNote = score[location] else { throw Self.refused(.noteNotFound(location)) }
        let veID = VoiceElementID(location)
        guard case var .chord(chord) = score[veID] else {
            throw Self.refused(.wrongElementKind(at: veID, expected: .chord))
        }
        chord.notes[location.noteIndexInChord].visible = visible
        score[veID] = .chord(chord)
        return SetNoteVisible(at: location, visible: oldNote.visible)
    }

    /// The flag on the note at `location`, or `nil` when there is no such note.
    static func current(at location: NoteID, in score: Score) -> Bool? {
        score[location]?.visible
    }
}
