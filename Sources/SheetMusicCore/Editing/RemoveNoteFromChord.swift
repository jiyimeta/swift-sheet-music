import Foundation

/// Inverse of `AddNoteToChord`: drop one note from a chord at the
/// given `NoteID`. When the chord's last note is removed the whole
/// element collapses to a `Rest` of the same duration — MuseScore's
/// behaviour when the user deletes the final notehead of a chord.
///
/// Inverse is a `ReplaceVoiceElement` carrying the prior chord, so
/// undo restores the chord verbatim (notes, lyrics, arpeggio,
/// duration). For the chord→rest collapse case this also restores
/// the chord-level metadata that was implicitly discarded.
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
        if chord.notes.count == 1 {
            score[veID] = .rest(Rest(duration: chord.duration))
        } else {
            chord.notes.remove(at: location.noteIndexInChord)
            score[veID] = .chord(chord)
        }
        return ReplaceVoiceElement(at: veID, with: .chord(original))
    }
}
