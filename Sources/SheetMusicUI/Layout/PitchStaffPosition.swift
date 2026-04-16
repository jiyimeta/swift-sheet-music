#if os(macOS)
import SheetMusicCore

/// Clef glyphs we currently place. Each clef anchors a reference pitch to
/// a reference staff line, from which all other pitches are derived.
@available(macOS 15.0, *)
public enum NotatedClef: Sendable, Equatable {
    case treble          // G4 on line 2 (second from bottom)
    case bass            // F3 on line 4 (second from top)
    case alto            // C4 on middle line
    case tenor           // C4 on line 4
    case percussion      // unpitched 5-line drum staff

    /// Parse a `Clef.concertClefType` string (MuseScore encoding).
    public init(rawType: String) {
        switch rawType {
        case "G", "G1", "G2", "G8va", "G8vb", "treble": self = .treble
        case "F", "F8va", "F8vb", "bass":              self = .bass
        case "C3", "alto":                              self = .alto
        case "C4", "tenor":                             self = .tenor
        case "PERC", "PERC2", "percussion":             self = .percussion
        default:                                        self = .treble
        }
    }
}

/// Result of mapping a MIDI pitch to a staff position under a given clef.
///
/// `step` values of 0 = middle line. +1 = space above middle line.
/// +2 = fourth line (from bottom). …etc. Each step = 0.5 sp vertically.
@available(macOS 15.0, *)
public struct StaffStep: Sendable, Equatable {
    public let step: Int
    public init(_ step: Int) { self.step = step }
}

/// Pure function: MIDI pitch + TPC + clef → staff step.
///
/// TPC ("tonal pitch class", -1..33 in MuseScore convention) selects the
/// diatonic spelling. Pitch alone is ambiguous (C♯ vs D♭). With TPC we can
/// place the notehead on the correct diatonic line/space.
@available(macOS 15.0, *)
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
        let midLineDiatonic: Int
        switch clef {
        case .treble:     midLineDiatonic = 4 * 7 + 6     // B4
        case .bass:       midLineDiatonic = 3 * 7 + 1     // D3
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
#endif
