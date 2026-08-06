import Foundation

/// Interval kind for the iPad chord-build shortcuts (spec §5.4): tap +3rd or +8ve to add a note above the
/// selected chord tone.
public enum EditorInterval: Sendable {
    case third
    case octave
}

/// Client-side pitch/tpc computation for the iPad interval shortcuts (spec §5.4): the engine has no interval
/// command, so the client computes the added note and issues `AddNoteToChord`.
public enum IntervalPlanner {
    /// Diatonic third above `note`, spelled in key (letter + 2 staff steps via `StaffStepPitch.diatonicShift`).
    /// `nil` past MIDI 127.
    public static func diatonicThirdAbove(_ note: Note, keySig: Int) -> (pitch: Int, tpc: Int)? {
        StaffStepPitch.diatonicShift(from: note, bySteps: 2, keySig: keySig)
    }

    /// Perfect octave above `note`, same tpc. `nil` past MIDI 127.
    public static func octaveAbove(_ note: Note) -> (pitch: Int, tpc: Int)? {
        let pitch = note.pitch + 12
        guard (0 ... 127).contains(pitch) else { return nil }
        return (pitch, note.tpc)
    }
}
