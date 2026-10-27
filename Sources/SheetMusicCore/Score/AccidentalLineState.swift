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

    /// Whether another note of `notes` stands on the written line of `notes[index]` with a different alteration — the
    /// unison MuseScore spells out on both notes (`hasAlteredUnison` in `note.cpp`). With F and F♯ in one chord the F
    /// draws its ♮ even where the bar already reads natural, and the F♯ its ♯ even after an earlier F♯. It decides a
    /// glyph only; the state is left as the bar had it.
    static func hasAlteredUnison(at index: Int, in notes: ChordNotes) -> Bool {
        guard let own = spelling(pitch: notes[index].pitch, tpc: notes[index].tpc) else { return false }
        return notes.indices.contains { other in
            guard other != index, let spelled = spelling(pitch: notes[other].pitch, tpc: notes[other].tpc)
            else { return false }
            return spelled.letter == own.letter && spelled.octave == own.octave
                && spelled.alteration != own.alteration
        }
    }

    /// TPC of each natural letter, `C D E F G A B` order.
    static let naturalTpcByLetter = [14, 16, 18, 13, 15, 17, 19]
    /// Semitone offset of each natural letter from C, `C D E F G A B` order.
    private static let naturalSemitoneByLetter = [0, 2, 4, 5, 7, 9, 11]

    /// The WRITTEN `(letter, octave, alteration)` behind a `pitch` / `tpc` pair — letter 0=C … 6=B, middle C in octave
    /// 4, alteration ♮=0, ♯=+1, ♭=−1 and so on — or nil when the two disagree or the tpc is outside MuseScore's range
    /// (`TPC_MIN = -1` F♭♭ … `TPC_MAX = 33` B♯♯). Callers must read nil as "say nothing about this note": a corrupt
    /// or unusual pairing would otherwise decide a glyph wrongly.
    static func spelling(pitch: Int, tpc: Int) -> (letter: Int, octave: Int, alteration: Int)? {
        guard (-1 ... 33).contains(tpc) else { return nil }
        let letter = letter(forTpc: tpc)
        let alteration = (tpc - naturalTpcByLetter[letter]) / 7
        let naturalSemi = naturalSemitoneByLetter[letter]
        let expectedPitchClass = ((naturalSemi + alteration) % 12 + 12) % 12
        guard ((pitch % 12) + 12) % 12 == expectedPitchClass else { return nil }
        return (letter, (pitch - naturalSemi - alteration) / 12 - 1, alteration)
    }

    /// Diatonic letter index (0=C … 6=B) of a TPC. `(tpc + 1) % 7` rotates the line of fifths to align with
    /// `F C G D A E B`; the table maps that rotation back to `C D E F G A B` order.
    static func letter(forTpc tpc: Int) -> Int {
        [3, 0, 4, 1, 5, 2, 6][((tpc + 1) % 7 + 7) % 7]
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
