import Foundation

/// TPC ↔ MIDI helpers for pitch-edit commands.
///
/// MuseScore's TPC (tonal pitch class) is the line-of-fifths index:
/// `... -1=Fbb, 0=Cbb, ..., 6=Fb, 7=Cb, ..., 13=F, 14=C, 15=G, 16=D,
///  17=A, 18=E, 19=B, 20=F#, 21=C#, ..., 26=B#, 27=Fx, ...`
///
/// `pitch` is MIDI 0…127. The pitch class (PC) of a TPC is its MIDI
/// modulo 12. Multiple TPCs map to one PC (e.g. C# = Db = 1).
public enum PitchSpelling {
    /// Compute a TPC for `newPitch` that is musically reasonable for
    /// a pitch-shift edit starting from `(priorPitch, priorTpc)`.
    ///
    /// Rule: direction-aware natural-neighbor spelling.
    /// - If `newPitch`'s pitch class is a natural (C, D, E, F, G, A,
    ///   B), return that natural's TPC.
    /// - Otherwise (a black-key pitch class):
    ///   - When the shift is upward (`newPitch >= priorPitch`),
    ///     prefer the **sharp of the lower natural** (D + 1 → D#).
    ///   - When downward (`newPitch < priorPitch`), prefer the
    ///     **flat of the upper natural** (D − 1 → Db).
    ///
    /// This matches the convention most notation editors use when
    /// arrow-key-transposing a note by a semitone. A more
    /// sophisticated rule would consult the active key signature and
    /// neighbouring notes; revisit if a key-aware rule becomes
    /// necessary.
    public static func shiftedTpc(
        from priorPitch: Int, priorTpc: Int, to newPitch: Int
    ) -> Int {
        let newPC = ((newPitch % 12) + 12) % 12
        // Naturals: pitch class → natural-letter TPC.
        let naturalTpc: [Int: Int] = [
            0: 14,   // C
            2: 16,   // D
            4: 18,   // E
            5: 13,   // F
            7: 15,   // G
            9: 17,   // A
            11: 19,  // B
        ]
        if let nat = naturalTpc[newPC] { return nat }
        // Direction-aware spelling for chromatic notes. Sharps live
        // 7 steps higher on the line of fifths than their natural;
        // flats live 7 steps lower.
        let ascending = newPitch >= priorPitch
        if ascending {
            // PC − 1 is the lower natural (e.g. PC 1 → C, PC 3 → D).
            if let lowerNat = naturalTpc[newPC - 1] {
                return lowerNat + 7
            }
        } else {
            // PC + 1 is the upper natural (e.g. PC 1 → D, PC 10 → B).
            if let upperNat = naturalTpc[newPC + 1] {
                return upperNat - 7
            }
        }
        // Defensive fallback. `newPC` is in 0…11 and every
        // chromatic PC has both a lower and upper natural neighbour
        // in 0…11, so this branch is unreachable for any in-range
        // input.
        return 14
    }
}

public extension Note {
    /// Return a copy of this note shifted by `delta` semitones.
    /// The new TPC is computed by `PitchSpelling.shiftedTpc`. The
    /// `accidental` override is preserved verbatim — callers that
    /// want the new pitch to use the staff's automatic accidental
    /// display should clear it themselves.
    ///
    /// Returns `nil` when the resulting pitch falls outside the
    /// MIDI range `0…127`.
    func shifted(bySemitones delta: Int) -> Note? {
        let newPitch = pitch + delta
        guard (0...127).contains(newPitch) else { return nil }
        let newTpc = PitchSpelling.shiftedTpc(
            from: pitch, priorTpc: tpc, to: newPitch)
        var copy = self
        copy.pitch = newPitch
        copy.tpc = newTpc
        return copy
    }
}
