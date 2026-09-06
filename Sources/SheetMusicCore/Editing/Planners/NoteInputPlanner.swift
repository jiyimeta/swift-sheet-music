import SheetMusicFoundation

/// Chooses the octave for a letter key: the candidate pitch closest to the reference (previous note), ties resolved
/// upward. Reference nil → octave 4 (MuseScore's default entry octave; NoteInputKeyMap octave 4 contains middle C).
public enum NoteInputPlanner {
    /// The lowest spelling of `letter` strictly ABOVE `referencePitch` — MuseScore's rule for a letter key that
    /// stacks onto a chord rather than writing a new one (`Score::resolveNoteInputParams`, whose `addFlag` branch
    /// is commented "if adding notes, add above the upNote of the current chord").
    ///
    /// It is a different question from `nearestTo`, not a variation on it: ⇧A on a chord topped by C3 means A3, and
    /// asking for the nearest A would answer A2 — a note BELOW the chord, which is not what "add a note to this
    /// chord" means to anyone building one upward. `nil` when no octave of the letter fits above the reference.
    ///
    /// Compare NATURAL pitches, as MuseScore does (it strips the reference's alteration before choosing): within an
    /// octave the natural pitches run in letter order, so "the lowest natural above" and MuseScore's step
    /// comparison (`if (note <= tpc2step(tpc)) octave++`) pick the same octave.
    public static func pitch(forLetter letter: Character, above referencePitch: Int) -> (pitch: Int, tpc: Int)? {
        var best: (pitch: Int, tpc: Int)?
        for octave in 0 ... 8 {
            guard let candidate = NoteInputKeyMap.pitch(forLetter: letter, octave: octave),
                  candidate.pitch > referencePitch
            else { continue }
            guard let current = best else {
                best = candidate
                continue
            }
            if candidate.pitch < current.pitch {
                best = candidate
            }
        }
        return best
    }

    public static func pitch(forLetter letter: Character, nearestTo referencePitch: Int?) -> (pitch: Int, tpc: Int)? {
        guard NoteInputKeyMap.pitch(forLetter: letter, octave: 4) != nil else { return nil }
        guard let referencePitch else {
            return NoteInputKeyMap.pitch(forLetter: letter, octave: 4)
        }
        var best: (pitch: Int, tpc: Int)?
        for octave in 0 ... 8 {
            guard let candidate = NoteInputKeyMap.pitch(forLetter: letter, octave: octave) else { continue }
            guard let current = best else {
                best = candidate
                continue
            }
            let candidateDistance = abs(candidate.pitch - referencePitch)
            let currentDistance = abs(current.pitch - referencePitch)
            if candidateDistance < currentDistance
                || (candidateDistance == currentDistance && candidate.pitch > current.pitch)
            {
                best = candidate
            }
        }
        return best
    }
}
