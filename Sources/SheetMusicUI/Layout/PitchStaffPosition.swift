import SheetMusicCore

/// Clef glyphs we currently place. Each clef anchors a reference pitch to
/// a reference staff line, from which all other pitches are derived.
@available(macOS 15.0, iOS 16.0, *)
public enum NotatedClef: Sendable, Equatable {
    case treble          // G4 on line 2 (second from bottom)
    case treble8va       // G clef, 8va alta — notes read 1 octave higher
    case treble8vb       // G clef, 8va bassa — 1 octave lower
    case treble15ma      // G clef, 15ma alta — 2 octaves higher
    case treble15mb      // G clef, 15ma bassa — 2 octaves lower
    case bass            // F3 on line 4 (second from top)
    case bass8va         // F clef, 8va alta
    case bass8vb         // F clef, 8va bassa
    case alto            // C4 on middle line
    case tenor           // C4 on line 4
    case percussion      // unpitched 5-line drum staff

    /// Parse a `Clef.concertClefType` string (MuseScore encoding).
    public init(rawType: String) {
        switch rawType {
        case "G", "G1", "G2", "treble":                 self = .treble
        case "G8va":                                     self = .treble8va
        case "G8vb":                                     self = .treble8vb
        case "G15ma":                                    self = .treble15ma
        case "G15mb":                                    self = .treble15mb
        case "F", "bass":                                self = .bass
        case "F8va":                                     self = .bass8va
        case "F8vb":                                     self = .bass8vb
        case "C3", "alto":                               self = .alto
        case "C4", "tenor":                              self = .tenor
        case "PERC", "PERC2", "percussion":              self = .percussion
        default:                                         self = .treble
        }
    }
}

/// Result of mapping a MIDI pitch to a staff position under a given clef.
///
/// `step` values of 0 = middle line. +1 = space above middle line.
/// +2 = fourth line (from bottom). …etc. Each step = 0.5 sp vertically.
@available(macOS 15.0, iOS 16.0, *)
public struct StaffStep: Sendable, Equatable {
    public let step: Int
    public init(_ step: Int) { self.step = step }
}

/// Pure function: MIDI pitch + TPC + clef → staff step.
///
/// TPC ("tonal pitch class", -1..33 in MuseScore convention) selects the
/// diatonic spelling. Pitch alone is ambiguous (C♯ vs D♭). With TPC we can
/// place the notehead on the correct diatonic line/space.
@available(macOS 15.0, iOS 16.0, *)
public enum PitchStaffPosition {
    /// Tonal pitch class → diatonic step count from C (0=C, 1=D, …, 6=B).
    /// MuseScore TPC: -1 = F♭♭, 0 = C♭♭, 1 = G♭♭, …
    /// (TPC mod 7 gives the diatonic letter in the order F C G D A E B.)
    private static let tpcLetters: [Int] = [3, 0, 4, 1, 5, 2, 6]
    // index by ((tpc + 1) mod 7): F(-1→0), C(0→1), G(1→2), D(2→3), A, E, B

    /// Return the staff step for a note with this pitch + tpc under `clef`.
    public static func step(
        midiPitch: Int,
        tpc: Int,
        clef: NotatedClef
    ) -> StaffStep {
        let diatonicFromC = tpcLetters[((tpc + 1) % 7 + 7) % 7]
        let octave = octaveFor(midiPitch: midiPitch, diatonicFromC: diatonicFromC)
        let diatonicAbs = octave * 7 + diatonicFromC
        // Diatonic step of the note sitting on the middle staff line
        // for each clef. Octave-transposing clefs shift the reference
        // by ±7 (one diatonic octave) or ±14 (two octaves).
        let midLineDiatonic: Int
        switch clef {
        case .treble:     midLineDiatonic = 4 * 7 + 6     // B4
        case .treble8va:  midLineDiatonic = 5 * 7 + 6     // B5
        case .treble8vb:  midLineDiatonic = 3 * 7 + 6     // B3
        case .treble15ma: midLineDiatonic = 6 * 7 + 6     // B6
        case .treble15mb: midLineDiatonic = 2 * 7 + 6     // B2
        case .bass:       midLineDiatonic = 3 * 7 + 1     // D3
        case .bass8va:    midLineDiatonic = 4 * 7 + 1     // D4
        case .bass8vb:    midLineDiatonic = 2 * 7 + 1     // D2
        case .alto:       midLineDiatonic = 4 * 7 + 0     // C4
        case .tenor:      midLineDiatonic = 3 * 7 + 5     // A3
        case .percussion: midLineDiatonic = 4 * 7 + 6     // positional (B4)
        }
        return StaffStep(diatonicAbs - midLineDiatonic)
    }

    /// The octave number implied by a MIDI pitch + diatonic letter.
    /// This resolves accidental ambiguity: pitch 60 + letter=B → octave 3
    /// (B♯3), not octave 4.
    private static func octaveFor(midiPitch: Int, diatonicFromC: Int) -> Int {
        // Semitone distance from C in the same octave for each letter:
        let letterSemitone = [0, 2, 4, 5, 7, 9, 11]  // C D E F G A B
        let naiveOctave = midiPitch / 12 - 1  // MIDI 0 = C-1
        let naiveSemitone = midiPitch - 12 * (naiveOctave + 1)
        let letterSem = letterSemitone[diatonicFromC]
        let diff = naiveSemitone - letterSem
        if diff >= 6 { return naiveOctave + 1 }
        if diff <= -6 { return naiveOctave - 1 }
        return naiveOctave
    }
}
