/// One written staff line's accidental state part-way through a bar — an entry of MuseScore's `AccidentalState`,
/// which packs the same two facts into one byte (`key.h`: the alteration, `| TIE_CONTEXT`).
///
/// Shared by the two passes that decide a glyph — `Score.suppressingRedundantAccidentals()` at layout and
/// `MeasureAccidentals`' renotation after an edit — so the rule they apply cannot drift apart.
struct AccidentalLineState: Equatable {
    /// The alteration in force on the line.
    var alteration: Int
    /// Whether that alteration reached the line only through a note tied over from the previous bar that drew no
    /// accidental of its own. The reader never saw it written in this bar, so the next note on the line restates
    /// its accidental even when the alteration is the same (`Note::updateAccidental`'s `as->tieContext(line)`).
    var tiedOver: Bool

    init(alteration: Int, tiedOver: Bool = false) {
        self.alteration = alteration
        self.tiedOver = tiedOver
    }

    /// Whether a note spelled with `alteration` has to draw its accidental against this state.
    func needsAccidental(for alteration: Int) -> Bool {
        alteration != self.alteration || tiedOver
    }

    /// The state after `note`, spelled with `alteration`, drawing an accidental or not as `drawsAccidental` says.
    ///
    /// Only a note that had to speak marks the line as tied over — a tied note whose alteration is already in force
    /// (a tie inside the bar, or one the key signature covers) leaves nothing to restate. MuseScore reaches the same
    /// state by setting `TIE_CONTEXT` only inside the branch that restates.
    func after(_ note: Note, alteration: Int, drawsAccidental: Bool) -> AccidentalLineState {
        AccidentalLineState(
            alteration: alteration,
            tiedOver: needsAccidental(for: alteration) && note.tieBack != nil && !drawsAccidental,
        )
    }

    /// Whether `note` is a tied continuation that draws no accidental of its own — the note a letter key reads past,
    /// since the reader never saw its alteration written in this bar (`Measure::findAccidental` skips
    /// `tieBack() && !accidental()`).
    static func isUnwrittenTie(_ note: Note) -> Bool {
        note.tieBack != nil && note.accidental == nil
    }

    /// The glyph a note spelled with `alteration` draws when it has to speak, or nil for an alteration no single glyph
    /// spells.
    static func glyph(forAlteration alteration: Int) -> Accidental? {
        switch alteration {
        case 0: .natural
        case 1: .sharp
        case -1: .flat
        case 2: .doubleSharp
        case -2: .doubleFlat
        case 3: .tripleSharp
        case -3: .tripleFlat
        default: nil
        }
    }
}
