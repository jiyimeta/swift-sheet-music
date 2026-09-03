import SheetMusicFoundation

/// Write (or clear) the glissando starting on one note — the sweep to the next chord's note.
///
/// `nil` clears. A write is refused on a note whose chord has no following sounding chord in its voice
/// (`.noNextChord`): the destination is implicit — `Note.glissando` names no target, and both the layout and the
/// renderer resolve it as "the next chord" (`Glissando.swift`) — so a glissando written on the last chord draws
/// a line to nothing and plays as nothing. A CLEAR skips the check, so a note that became the last one after an
/// edit stays editable.
///
/// The check crosses bar lines, unlike `SetTremolo`'s: a glissando into the next measure is ordinary notation.
/// It does not inspect the destination chord's notes — the renderer takes whatever is there, as MuseScore's does.
///
/// > Note: This command is sugar over `ReplaceVoiceElement`, the same shape `SetNoteHead` has. See
/// > `docs/edit-commands.md`.
public struct SetGlissando: EditCommand {
    public let location: NoteID
    public let glissando: Glissando?

    public init(at location: NoteID, glissando: Glissando?) {
        self.location = location
        self.glissando = glissando
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(location)
    }

    /// The note's glissando, or `nil` both when there is none and when `location` names no note — what a planner
    /// reads to decide whether an intent restates the score.
    static func current(at location: NoteID, in score: Score) -> Glissando? {
        score[location]?.glissando
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let oldNote = score[location] else {
            throw Self.refused(.noteNotFound(location))
        }
        let elementID = VoiceElementID(location)
        guard case var .chord(chord) = score[elementID] else {
            throw Self.refused(.wrongElementKind(at: elementID, expected: .chord))
        }
        if glissando != nil, !NextChordProbe.hasFollowingChord(after: elementID, in: score) {
            throw Self.refused(.noNextChord(at: elementID))
        }
        chord.notes[location.noteIndexInChord].glissando = glissando
        score[elementID] = .chord(chord)
        return SetGlissando(at: location, glissando: oldNote.glissando)
    }
}
