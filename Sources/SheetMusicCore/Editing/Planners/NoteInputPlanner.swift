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

    /// The octave a letter key writes when there is NO previous note to measure against, chosen from the clef —
    /// MuseScore's `Score::resolveNoteInputParams` (`engraving/editing/cmd.cpp`), ported arithmetic and all.
    ///
    /// `clefAnchor` is the natural pitch on the staff's MIDDLE line. That is MuseScore's own anchor: walking back
    /// from the caret it stops at the clef (the header clef at tick 0 counts, which is why this fires for the first
    /// note of a score) and takes `line2pitch(4, clefType, Key::C)` — four diatonic steps down from the top line,
    /// which on a five-line staff IS the middle line. (The source's comment there says "C 72 for treble clef"; the
    /// value is B4 = 71. The comment is off by a step, the code is not.)
    ///
    /// The octave is then whichever puts the letter within a tritone of that anchor, and the ±6 comparison is
    /// deliberately asymmetric — `delta < -6` rather than `<= -6` — so a letter exactly a tritone from the anchor
    /// takes the LOWER octave. F under a treble clef is the case that hangs on it: F4 (first space) and F5 (top
    /// line) are equally far from B4 and both sit in the staff, and MuseScore writes F4. That is the opposite of
    /// `nearestTo`'s upward tie-break, which is why this is its own function rather than a call into that one.
    ///
    /// Compares NATURAL pitches against a natural anchor, as MuseScore does — it passes `Key::C` explicitly and
    /// strips the reference's alteration on the other branch. The bar's accidental state respells the result
    /// afterwards; it does not move the octave.
    public static func pitch(forLetter letter: Character, clefAnchor: Int) -> (pitch: Int, tpc: Int)? {
        guard let natural = NoteInputKeyMap.pitch(forLetter: letter, octave: 4) else { return nil }
        let semitone = natural.pitch % 12
        var octave = clefAnchor / 12
        let delta = octave * 12 + semitone - clefAnchor
        if delta > 6 {
            octave -= 1
        } else if delta < -6 {
            octave += 1
        }
        // MuseScore counts octaves from C-1 (pitch = octave * 12 + semitone); `NoteInputKeyMap` counts from C0,
        // where octave 4 holds middle C. One step between the two conventions, applied here so the ported
        // arithmetic above can stay in MuseScore's.
        return NoteInputKeyMap.pitch(forLetter: letter, octave: octave - 1)
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
