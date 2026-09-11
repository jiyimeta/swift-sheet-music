import SheetMusicFoundation

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

    /// The note the MIDDLE staff line carries under this clef, as an absolute diatonic index (`octave * 7 + letter`,
    /// C = 0) — B4 = 34 under a treble clef, D3 = 22 under a bass clef.
    ///
    /// This is the anchor the enum's own doc comment promises ("each clef anchors a reference pitch to a reference
    /// staff line"), and it is what makes the clef mean something to code that is not drawing it: `SheetMusicLayout`
    /// derives every notehead's staff step from it, and note input derives the octave a letter key writes into an
    /// empty staff from it. Both used to carry their own answer — layout a complete table, input a hard-coded
    /// octave 4 — and the second was wrong for every clef but the treble.
    ///
    /// Octave-transposing clefs shift the anchor by ±7 (one diatonic octave) or ±14, so a `G8vb` staff reads and
    /// writes an octave below a `G` one. The two percussion clefs have no pitch to anchor; they answer with the
    /// treble's B4, which is the positional convention layout already draws them by, and which leaves unpitched
    /// staves behaving exactly as they did.
    public var middleLineDiatonicStep: Int {
        switch self {
        case .treble: 4 * 7 + 6 // B4
        case .treble8va: 5 * 7 + 6 // B5
        case .treble8vb: 3 * 7 + 6 // B3
        case .treble15ma: 6 * 7 + 6 // B6
        case .treble15mb: 2 * 7 + 6 // B2
        case .bass: 3 * 7 + 1 // D3
        case .bass8va: 4 * 7 + 1 // D4
        case .bass8vb: 2 * 7 + 1 // D2
        case .soprano: 4 * 7 + 4 // G4
        case .alto: 4 * 7 + 0 // C4
        case .tenor: 3 * 7 + 5 // A3
        case .baritone: 3 * 7 + 3 // F3
        case .percussion: 4 * 7 + 6 // positional (B4)
        case .percussion2: 4 * 7 + 6 // positional (B4)
        }
    }

    /// MIDI pitch of the natural note on the middle staff line — `middleLineDiatonicStep` sounded rather than
    /// counted. Treble → 71 (B4), bass → 50 (D3).
    ///
    /// Natural by construction: a staff line names a letter, and what the key signature or the bar does to that
    /// letter is a separate question the caller already has an answer for. Used as the reference pitch when a letter
    /// key has no previous note to measure against, so the letter lands in the staff the user is looking at.
    public var middleLinePitch: Int {
        let semitoneForLetter = [0, 2, 4, 5, 7, 9, 11] // C D E F G A B
        let step = middleLineDiatonicStep
        let octave = step / 7
        return (octave + 1) * 12 + semitoneForLetter[step % 7]
    }
}
