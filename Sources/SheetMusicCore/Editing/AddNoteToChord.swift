import Foundation

/// Append a note to an existing chord's `notes` array. Used to
/// build chords interactively (Shift+letter in the macOS example).
///
/// Refuses when the chord already contains a note of the same MIDI
/// pitch — duplicate pitches in a chord are unidiomatic and the
/// edit would silently lose the user's input.
///
/// Inverse is a `ReplaceVoiceElement` carrying the prior chord, so
/// undo restores the chord's original notes (and any chord-level
/// metadata — arpeggio, lyrics, etc.) verbatim.
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
        guard case .chord(var chord) = score[location] else {
            throw SheetMusicError.invalidEdit(
                reason: "AddNoteToChord: element at \(location) "
                    + "is not a chord")
        }
        if chord.notes.contains(where: { $0.pitch == pitch }) {
            throw SheetMusicError.invalidEdit(
                reason: "AddNoteToChord: chord already contains a "
                    + "note at MIDI pitch \(pitch)")
        }
        let original = chord
        chord.notes.append(Note(
            pitch: pitch, tpc: tpc, accidental: accidental))
        score[location] = .chord(chord)
        return ReplaceVoiceElement(
            at: location, with: .chord(original))
    }
}
