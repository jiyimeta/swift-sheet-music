import SheetMusicFoundation

/// A diatonic interval above a selected chord tone: a third or an octave.
///
/// Superseded by `IntervalPlanner.note(_:above:keySig:)`, which takes any interval number. Kept because it is
/// public API and the two named cases still read well at a call site that only ever wants one of them.
public enum DiatonicInterval: Sendable {
    case third
    case octave
}

/// Client-side pitch/tpc computation for adding a note a diatonic interval above an existing chord tone: the
/// engine has no interval command, so the client computes the added note and issues `AddNoteToChord`.
public enum IntervalPlanner {
    /// The pitch and spelling a diatonic interval of `degrees` from `note` lands on — MuseScore's
    /// `Score::addInterval` rule (`engraving/editing/cmd.cpp`), which is what `Alt`+1…0 there produce.
    ///
    /// `degrees` is the interval NUMBER and carries the direction: `3` is a third above, `-3` a third below. The
    /// staff-step delta is one less than the number, since a third is two steps up the staff and an octave seven.
    ///
    /// **A whole number of octaves keeps the reference's own spelling** rather than re-reading the key — MuseScore's
    /// `useOctaveRule`, which covers the unison and the octave. An octave above a C♯ is a C♯; asking the key
    /// signature instead would hand back the C that the key spells, which is a different note. Every other interval
    /// IS read from the key: a third above D in D major is the F♯ the signature spells, not an F.
    ///
    /// `nil` when the result would leave MIDI 0…127.
    public static func note(
        _ degrees: Int, above note: Note, keySig: Int,
    ) -> (pitch: Int, tpc: Int)? {
        let stepDelta = (abs(degrees) - 1) * (degrees > 0 ? 1 : -1)
        guard stepDelta % 7 != 0 else {
            let pitch = note.pitch + 12 * (stepDelta / 7)
            return (0 ... 127).contains(pitch) ? (pitch, note.tpc) : nil
        }
        return StaffStepPitch.diatonicShift(from: note, bySteps: stepDelta, keySig: keySig)
    }

    /// Diatonic third above `note`, spelled in key (letter + 2 staff steps via `StaffStepPitch.diatonicShift`).
    /// `nil` past MIDI 127.
    public static func diatonicThirdAbove(_ note: Note, keySig: Int) -> (pitch: Int, tpc: Int)? {
        self.note(3, above: note, keySig: keySig)
    }

    /// Perfect octave above `note`, same tpc. `nil` past MIDI 127.
    public static func octaveAbove(_ note: Note) -> (pitch: Int, tpc: Int)? {
        // `keySig` is unused by the octave branch — it is the one interval that does not consult the key.
        self.note(8, above: note, keySig: 0)
    }
}
