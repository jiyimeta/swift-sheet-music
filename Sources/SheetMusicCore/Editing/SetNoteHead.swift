import SheetMusicFoundation

/// Write (or clear) one note's notehead override — MuseScore's `<head>`, which round-trips through MSCX on both
/// the decode and encode side.
///
/// The reason it exists: `InputNote` and `AddNoteToChord` carry `pitch` and `tpc` only, so a cross-notehead
/// hi-hat cannot be written by either. Composing the write with this one is what makes a drum key's whole
/// meaning — pitch, head and voice — reachable in a single undo step, without widening a wire payload whose byte
/// layout is already committed.
///
/// `nil` clears the override, which lets the note fall back to the duration-based head the engraver would draw.
///
/// > Note: This command is sugar over `ReplaceVoiceElement` + `CompositeEditCommand`. It exists to give the
/// > operation a domain-meaningful name and to centralise the small bit of validation it performs; callers can
/// > equally well construct the equivalent Composite directly. See `docs/edit-commands.md` for the policy.
public struct SetNoteHead: EditCommand {
    public let location: NoteID
    public let headType: String?

    public init(at location: NoteID, headType: String?) {
        self.location = location
        self.headType = headType
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
        chord.notes[location.noteIndexInChord].headType = headType
        score[veID] = .chord(chord)
        return SetNoteHead(at: location, headType: oldNote.headType)
    }
}
