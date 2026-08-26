import SheetMusicFoundation

/// Chooses the octave for a letter key: the candidate pitch closest to the reference (previous note), ties resolved
/// upward. Reference nil → octave 4 (MuseScore's default entry octave; NoteInputKeyMap octave 4 contains middle C).
public enum NoteInputPlanner {
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
