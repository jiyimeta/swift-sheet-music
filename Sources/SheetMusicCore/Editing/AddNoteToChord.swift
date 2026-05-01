import Foundation

/// Append a note to an existing chord's `notes`. Used to build
/// chords interactively (Shift+letter in the macOS example).
///
/// `ChordNotes` enforces pitch-uniqueness structurally — `append`
/// silently dedupes — so this command's pre-check exists only to
/// surface a clear "this pitch already exists" error to the host
/// instead of the operation no-op'ing. Refusal goes through
/// `ChordNotes.tryAppend(_:) -> Bool`.
///
/// Inverse is a `ReplaceVoiceElement` carrying the prior chord, so
/// undo restores the chord's original notes (and any chord-level
/// metadata — arpeggio, lyrics, etc.) verbatim.
///
/// > Note: This command is sugar over `ChordNotes.tryAppend(_:)`
/// > + `ReplaceVoiceElement`. It exists to give the operation a
/// > domain-meaningful name and to surface the duplicate-pitch
/// > rejection as an explicit `invalidEdit` error; callers can
/// > equally construct the equivalent `ReplaceVoiceElement`
/// > directly (and check `tryAppend`'s `Bool` return). See
/// > `docs/edit-commands.md` for the policy.
public struct AddNoteToChord: EditCommand {
    public let location: VoiceElementID
    public let pitch: Int
    public let tpc: Int
    public let accidental: Accidental?

    public init(
        at location: VoiceElementID,
        pitch: Int,
        tpc: Int,
        accidental: Accidental? = nil
    ) {
        self.location = location
        self.pitch = pitch
        self.tpc = tpc
        self.accidental = accidental
    }

    public var affectedLocation: VoiceElementID { location }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard case var .chord(chord) = score[location],
              !chord.notes.isEmpty
        else {
            throw SheetMusicError.invalidEdit(
                reason: "AddNoteToChord: element at \(location) "
                    + "is not a chord (need at least one existing "
                    + "note; use ReplaceVoiceElement to seed a "
                    + "chord onto a rest)")
        }
        let original = chord
        let added = chord.notes.tryAppend(Note(
            pitch: pitch, tpc: tpc, accidental: accidental
        ))
        guard added else {
            throw SheetMusicError.invalidEdit(
                reason: "AddNoteToChord: chord already contains a "
                    + "note at MIDI pitch \(pitch)")
        }
        score[location] = .chord(chord)
        return ReplaceVoiceElement(
            at: location, with: .chord(original)
        )
    }
}
