import SheetMusicFoundation

/// Maps a keyboard letter (C..B) and an octave to the `(pitch, tpc)`
/// pair used by `Note`.
///
/// The TPC choice is the *natural* spelling — F=13, C=14, G=15,
/// D=16, A=17, E=18, B=19. Sharps / flats are out of scope for the
/// initial input slice.
public enum NoteInputKeyMap {
    /// Returns the natural-spelling `(pitch, tpc)` for `letter` in
    /// `octave`, where octave 4 contains middle C (MIDI 60). Returns
    /// `nil` if `letter` is not one of `c d e f g a b` (case
    /// insensitive).
    public static func pitch(
        forLetter letter: Character, octave: Int,
    ) -> (pitch: Int, tpc: Int)? {
        let lower = Character(letter.lowercased())
        let pitchOffset: Int
        let tpc: Int
        switch lower {
        case "c": pitchOffset = 0; tpc = 14
        case "d": pitchOffset = 2; tpc = 16
        case "e": pitchOffset = 4; tpc = 18
        case "f": pitchOffset = 5; tpc = 13
        case "g": pitchOffset = 7; tpc = 15
        case "a": pitchOffset = 9; tpc = 17
        case "b": pitchOffset = 11; tpc = 19
        default: return nil
        }
        // MIDI 0 is C(-1); octave 4 contains MIDI 60.
        let pitch = (octave + 1) * 12 + pitchOffset
        return (pitch, tpc)
    }

    /// Returns the `NoteDuration` MuseScore assigns to a typed digit
    /// for arrow-style duration changes:
    ///   1 → 64th, 2 → 32nd, 3 → 16th, 4 → 8th,
    ///   5 → quarter, 6 → half, 7 → whole.
    /// Returns `nil` for any other character.
    public static func duration(
        forCharacter character: String,
    ) -> NoteDuration? {
        switch character {
        case "1": return .sixtyFourth
        case "2": return .thirtySecond
        case "3": return .sixteenth
        case "4": return .eighth
        case "5": return .quarter
        case "6": return .half
        case "7": return .whole
        default: return nil
        }
    }
}
