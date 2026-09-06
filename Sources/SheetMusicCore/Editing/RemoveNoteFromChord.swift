import SheetMusicFoundation

/// Inverse of `AddNoteToChord`: drop one note from a chord at the
/// given `NoteID`. Removing the last note leaves the chord with an
/// empty `notes` array — which is the canonical representation of a
/// rest in this model, so layout and MIDI keep working without any
/// special-casing.
///
/// Inverse is a `ReplaceVoiceElement` carrying the prior chord, so
/// undo restores the chord verbatim (notes, lyrics, arpeggio,
/// duration), including chord-level metadata that the empty-chord
/// path implicitly suppresses.
///
/// > Note: This command is sugar over chord-notes mutation +
/// > `ReplaceVoiceElement`. It exists to give the operation a
/// > domain-meaningful name and to handle the "lyrics / arpeggio
/// > strip when collapsing to a rest" detail in one place;
/// > callers can equally construct the equivalent
/// > `ReplaceVoiceElement` directly. See
/// > `docs/edit-commands.md` for the policy.
public struct RemoveNoteFromChord: EditCommand {
    public let location: NoteID

    public init(at location: NoteID) {
        self.location = location
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(location)
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        let veID = VoiceElementID(location)
        guard case var .chord(chord) = score[veID] else {
            throw Self.refused(.wrongElementKind(at: veID, expected: .chord))
        }
        guard chord.notes.indices.contains(location.noteIndexInChord)
        else {
            throw Self.refused(.noteNotFound(location))
        }
        let original = chord
        chord.notes.remove(at: location.noteIndexInChord)
        // chord-level metadata (lyrics, arpeggio, bracket) on a rest is
        // unusual, so strip it. The original is preserved in the
        // inverse for undo.
        //
        // `bracket` in particular must go: `encodeAsRest` deliberately never
        // writes `<ChordBracket>` (read460 only accepts it on a `<Chord>`),
        // but the fingerprint hashes it, so a bracket left on a rest would
        // change the score's `stableFingerprint` across a save/reload.
        if chord.notes.isEmpty {
            chord.lyrics = []
            chord.arpeggio = nil
            chord.bracket = nil
        }
        score[veID] = .chord(chord)
        return ReplaceVoiceElement(at: veID, with: .chord(original))
    }
}
