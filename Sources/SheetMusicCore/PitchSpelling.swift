import Foundation

/// TPC ↔ MIDI helpers for pitch-edit commands.
///
/// MuseScore's TPC (tonal pitch class) is the line-of-fifths index:
/// `... -1=Fbb, 0=Cbb, ..., 6=Fb, 7=Cb, ..., 13=F, 14=C, 15=G, 16=D,
///  17=A, 18=E, 19=B, 20=F#, 21=C#, ..., 26=B#, 27=Fx, ...`
///
/// Useful TPC arithmetic:
///   `tpc + 7` → same letter, +1 alteration (sharper). Pitch +1.
///   `tpc - 7` → same letter, −1 alteration (flatter). Pitch −1.
///   `tpc - 5` → next letter alphabetically, adjusted to land +1
///                semitone above prior. Pitch +1.
///   `tpc + 5` → previous letter alphabetically, adjusted to land
///                −1 semitone below prior. Pitch −1.
public enum PitchSpelling {
    /// Compute a TPC for `newPitch` using MuseScore's chromatic-shift
    /// rule (`engraving/editing/editnote.cpp:upDownChromatic`).
    ///
    /// `keySig` is the active concert-key value (`-7…+7`; flats
    /// negative, sharps positive). For unit shifts (|delta| = 1)
    /// this matches MuseScore's arrow-key transpose. For larger
    /// shifts use `Note.shifted(bySemitones:in:)` which iterates the
    /// rule one semitone at a time.
    ///
    /// Predicate (up): `tpc > TPC_A + keySig` → diatonic (`tpc − 5`).
    ///                  Else                   → chromatic (`tpc + 7`).
    /// Predicate (dn): `tpc > TPC_C + keySig` → chromatic (`tpc − 7`).
    ///                  Else                   → diatonic (`tpc + 5`).
    ///
    /// In a flat-heavy key the predicate's threshold drops, so a
    /// note already at or below the key sig advances by changing
    /// letter (diatonic), while one above advances by adding more
    /// alteration on the same letter (chromatic). The two rules
    /// alternate as the user holds ↑/↓, producing the
    /// "C → D♭ → D♮ → E♭ → E♮ → F" pattern in A♭ major (and the
    /// symmetric flatward sequence on the way down).
    public static func shiftedTpc(
        from priorPitch: Int, priorTpc: Int,
        to newPitch: Int,
        in keySig: Int = 0,
    ) -> Int {
        if newPitch > priorPitch {
            if priorTpc > tpcA + keySig {
                return priorTpc - 5
            }
            return priorTpc + 7
        }
        if newPitch < priorPitch {
            if priorTpc > tpcC + keySig {
                return priorTpc - 7
            }
            return priorTpc + 5
        }
        return priorTpc
    }

    /// MuseScore's `Tpc::TPC_A` — the TPC of A natural.
    private static let tpcA = 17
    /// MuseScore's `Tpc::TPC_C` — the TPC of C natural.
    private static let tpcC = 14

    /// TPC of each natural letter (`C, D, E, F, G, A, B`). `letter`
    /// is the diatonic letter index (0…6, C-D-E-F-G-A-B order).
    private static let naturalTpcByLetter: [Int] =
        [14, 16, 18, 13, 15, 17, 19]
    /// Semitone offset of each natural letter from C (`C, D, E, F,
    /// G, A, B`).
    private static let naturalSemitoneByLetter: [Int] =
        [0, 2, 4, 5, 7, 9, 11]

    /// Diatonic letter index (0=C … 6=B) of a TPC.
    /// `(tpc + 1) % 7` rotates the line of fifths to align with
    /// `F C G D A E B`; the returned table maps to
    /// `C D E F G A B` order so callers can index `naturalTpcByLetter`
    /// and `naturalSemitoneByLetter` directly.
    private static func letterIndex(forTpc tpc: Int) -> Int {
        let table = [3, 0, 4, 1, 5, 2, 6]
        return table[((tpc + 1) % 7 + 7) % 7]
    }

    private static func semitoneShift(of accidental: Accidental?) -> Int {
        accidental?.semitoneOffset ?? 0
    }

    /// Re-spell `note` so it carries the requested `accidental`,
    /// preserving the diatonic letter (C → C♯, D♭ → D♮, etc.). The
    /// pitch shifts by the alteration delta; the TPC moves to the
    /// new (letter, alteration) pair on the line of fifths.
    ///
    /// Passing `accidental: nil` is a no-op for pitch and TPC — the
    /// caller wants only to clear the displayed glyph (e.g. so a
    /// note revert to "implied by key signature").
    public static func respelled(
        from note: Note, with accidental: Accidental?,
    ) -> (pitch: Int, tpc: Int) {
        guard let target = accidental else {
            return (note.pitch, note.tpc)
        }
        let letter = letterIndex(forTpc: note.tpc)
        let naturalSemi = naturalSemitoneByLetter[letter]
        // Octave is whichever places the note's natural pitch
        // closest to the existing pitch — works for any current
        // accidental within ±2 semitones of natural.
        let approxOctave = Int(((
            Double(note.pitch)
                - Double(naturalSemi)
        ) / 12.0).rounded()) - 1
        let shift = semitoneShift(of: target)
        let newPitch = 12 * (approxOctave + 1) + naturalSemi + shift
        let newTpc = naturalTpcByLetter[letter] + 7 * shift
        return (newPitch, newTpc)
    }

    /// Return the accidental glyph that should be drawn for a note
    /// with the given `tpc` under the active `keySig`, or `nil`
    /// when the note's alteration matches the key signature for its
    /// letter (and so needs no symbol).
    ///
    /// Examples (A♭ major, `keySig = -4`):
    ///   C  (TPC 14) → nil    (C natural matches key alt 0)
    ///   C♭ (TPC 7)  → .flat
    ///   B♭ (TPC 12) → nil    (matches key alt −1)
    ///   B♭♭(TPC 5)  → .doubleFlat
    ///   D♮ (TPC 16) → .natural (cancels key D♭)
    ///
    /// Doesn't account for prior accidentals on the same letter
    /// within the same measure — callers that need that behavior
    /// (e.g. cancelling a mid-measure ♯ with ♮) should compute it
    /// themselves and override.
    public static func displayedAccidental(
        forTpc tpc: Int, in keySig: Int,
    ) -> Accidental? {
        let centered = tpc - 13
        // Position in line of fifths from F (FCGDAEB = 0…6).
        let posInFifths = ((centered % 7) + 7) % 7
        let alteration = (centered - posInFifths) / 7
        let keyAlteration: Int
        if keySig > 0 {
            keyAlteration = posInFifths < keySig ? 1 : 0
        } else if keySig < 0 {
            // BEADGCF position = 6 − line-of-fifths position.
            let posInFlats = 6 - posInFifths
            keyAlteration = posInFlats < -keySig ? -1 : 0
        } else {
            keyAlteration = 0
        }
        if alteration == keyAlteration { return nil }
        switch alteration {
        case 0: return .natural
        case 1: return .sharp
        case -1: return .flat
        case 2: return .doubleSharp
        case -2: return .doubleFlat
        default: return nil
        }
    }
}

extension Note {
    /// Return a copy of this note shifted by `delta` semitones.
    /// Each semitone step is computed via
    /// `PitchSpelling.shiftedTpc(... in: keySig)`, applied
    /// iteratively so that multi-semitone shifts produce the same
    /// sequence the user would see by repeatedly pressing ↑/↓.
    ///
    /// Returns `nil` when the resulting pitch falls outside the
    /// MIDI range `0…127`.
    public func shifted(bySemitones delta: Int, in keySig: Int = 0) -> Note? {
        if delta == 0 { return self }
        let direction = delta > 0 ? 1 : -1
        var current = self
        for _ in 0 ..< abs(delta) {
            let nextPitch = current.pitch + direction
            guard (0 ... 127).contains(nextPitch) else { return nil }
            current.tpc = PitchSpelling.shiftedTpc(
                from: current.pitch, priorTpc: current.tpc,
                to: nextPitch, in: keySig,
            )
            current.pitch = nextPitch
        }
        // Refresh the accidental override to match the new TPC vs
        // the active key sig. Without this, the layout renderer (which
        // reads `note.accidental` verbatim) would keep showing whatever
        // the prior note had — usually nil, leaving newly-altered notes
        // with no visible flat / sharp / natural sign.
        current.accidental = PitchSpelling.displayedAccidental(
            forTpc: current.tpc, in: keySig,
        )
        return current
    }
}
