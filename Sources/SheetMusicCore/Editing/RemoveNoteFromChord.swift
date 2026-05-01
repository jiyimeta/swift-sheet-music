import Foundation

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
        guard case .chord(var chord) = score[veID] else {
            throw SheetMusicError.invalidEdit(
                reason: "RemoveNoteFromChord: element at \(veID) "
                    + "is not a chord")
        }
        guard chord.notes.indices.contains(location.noteIndexInChord)
        else {
            throw SheetMusicError.invalidEdit(
                reason: "RemoveNoteFromChord: chord has no note "
                    + "at index \(location.noteIndexInChord)")
        }
        let original = chord
        chord.notes.remove(at: location.noteIndexInChord)
        // chord-level metadata (lyrics, arpeggio) on a rest is
        // unusual, so strip it. The original is preserved in the
        // inverse for undo.
        if chord.notes.isEmpty {
            chord.lyrics = []
            chord.arpeggio = nil
        }
        score[veID] = .chord(chord)
        return ReplaceVoiceElement(at: veID, with: .chord(original))
    }
}
