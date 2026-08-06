import Foundation

/// A diatonic interval above a selected chord tone: a third or an octave.
public enum DiatonicInterval: Sendable {
    case third
    case octave
}

/// Client-side pitch/tpc computation for adding a note a diatonic interval above an existing chord tone: the
/// engine has no interval command, so the client computes the added note and issues `AddNoteToChord`.
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
