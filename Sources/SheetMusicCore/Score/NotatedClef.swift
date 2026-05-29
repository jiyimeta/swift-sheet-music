import Foundation

/// One of the clef glyphs the engraving / layout pipeline knows how
/// to place. Each clef anchors a reference pitch to a reference staff
/// line; from that anchor all other pitches are derived.
///
/// Distinct from `Clef` (a value placed in a `Voice` that records a
/// concert + transposing clef-type pair). This enum is the typed view
/// of a single clef glyph, useful when an API needs to enumerate or
/// constrain the recognized set (e.g. MIDI import clef inference).
public enum NotatedClef: Sendable, Equatable, Hashable, CaseIterable {
    case treble // G4 on line 2 (second from bottom)
    case treble8va // G clef, 8va alta — notes read 1 octave higher
    case treble8vb // G clef, 8va bassa — 1 octave lower
    case treble15ma // G clef, 15ma alta — 2 octaves higher
    case treble15mb // G clef, 15ma bassa — 2 octaves lower
    case bass // F3 on line 4 (second from top)
    case bass8va // F clef, 8va alta
    case bass8vb // F clef, 8va bassa
    case soprano // C4 on line 1 (bottom)
    case alto // C4 on middle line
    case tenor // C4 on line 4
    case baritone // C4 on line 5 (top)
    case percussion // unpitched 5-line drum staff (single rectangle glyph)
    case percussion2 // unpitched 5-line drum staff (two vertical bars glyph)

    /// Parse a `Clef.concertClefType` string (MuseScore encoding).
    /// Accepts canonical forms (`"G"`, `"F8vb"`, …) and the legacy
    /// aliases MuseScore itself emits (`"treble"`, `"bass"`, …).
    /// Unrecognized strings collapse to `.treble`.
    public init(rawType: String) {
        switch rawType {
        case "G", "G1", "G2", "treble": self = .treble
        case "G8va": self = .treble8va
        case "G8vb": self = .treble8vb
        case "G15ma": self = .treble15ma
        case "G15mb": self = .treble15mb
        case "F", "bass": self = .bass
        case "F8va": self = .bass8va
        case "F8vb": self = .bass8vb
        case "C1", "soprano": self = .soprano
        case "C3", "alto": self = .alto
        case "C4", "tenor": self = .tenor
        case "C5", "baritone": self = .baritone
        case "PERC", "percussion": self = .percussion
        case "PERC2": self = .percussion2
        default: self = .treble
        }
    }

    /// Canonical MuseScore-style clef identifier. Inverse of
    /// `init(rawType:)` for the forms we emit — callers use this when
    /// they need to carry an active clef forward as a string (e.g.,
    /// synthesising a clef at the start of a continuation system, or
    /// populating `Staff.defaultClefType`).
    public var rawType: String {
        switch self {
        case .treble: "G"
        case .treble8va: "G8va"
        case .treble8vb: "G8vb"
        case .treble15ma: "G15ma"
        case .treble15mb: "G15mb"
        case .bass: "F"
        case .bass8va: "F8va"
        case .bass8vb: "F8vb"
        case .soprano: "C1"
        case .alto: "C3"
        case .tenor: "C4"
        case .baritone: "C5"
        case .percussion: "PERC"
        case .percussion2: "PERC2"
        }
    }
}
