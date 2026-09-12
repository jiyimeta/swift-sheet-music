import SheetMusicFoundation

/// Writes one note's cue-size flag — MuseScore's `<small>`, which round-trips through MSCX and reaches the page
/// as the chord's magnification (`LayoutEngine+Placement.swift`, `chordMag`): a chord draws small when ANY of its
/// notes is small, matching MuseScore's own `mag` derivation.
///
/// Deliberately per-note, with no whole-chord form. MuseScore's `<small>` on a `<Chord>` is normalized onto the
/// chord's notes at decode (`MSCXDecoder+Chord.swift`), so `Chord` carries no such field, and a host that wants
/// MuseScore's chord-wide checkbox composes one command per note. That keeps undo one field per note, the same
/// choice `SetElementVisible` documents for its per-note flags.
///
/// > Note: This command is sugar over `ReplaceVoiceElement`. It exists to give the operation a domain-meaningful
/// > name and to centralise the small bit of validation it performs; callers can equally well construct the
/// > equivalent primitive directly. See `docs/edit-commands.md` for the policy.
public struct SetNoteSmall: EditCommand {
    public let location: NoteID
    public let isSmall: Bool

    public init(at location: NoteID, isSmall: Bool) {
        self.location = location
        self.isSmall = isSmall
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
        chord.notes.updateNote(at: location.noteIndexInChord) { $0.isSmall = isSmall }
        score[veID] = .chord(chord)
        return SetNoteSmall(at: location, isSmall: oldNote.isSmall)
    }
}
