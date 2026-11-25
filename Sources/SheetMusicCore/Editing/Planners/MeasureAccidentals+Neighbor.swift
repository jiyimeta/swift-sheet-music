import SheetMusicFoundation

extension MeasureAccidentals {
    /// How many semitones lie between `note` and the note `steps` staff lines or spaces away, read as a player reads
    /// the bar at `tick`: the neighboring line carries the last accidental written on it earlier in the bar, or else
    /// the key signature's alteration. Negative below the note. MuseScore's `chromaticPitchSteps` (`dom/utils.cpp`),
    /// which decides the auxiliary note of an ornament whose interval is `auto`.
    ///
    /// Concert pitch and concert key throughout: a transposing staff moves every line by one interval, so the distance
    /// is the same on either side.
    ///
    /// `nil` for a note whose `pitch` and `tpc` disagree, about which nothing can be said.
    package static func semitones(
        from note: Note,
        bySteps steps: Int,
        tick: Int,
        in measure: Measure,
        keySig: Int,
        division: Int,
        measureDuration: Fraction,
    ) -> Int? {
        guard let written = AccidentalLineState.spelling(pitch: note.pitch, tpc: note.tpc) else { return nil }
        let rawLetter = written.letter + steps
        let letter = ((rawLetter % 7) + 7) % 7
        let octave = written.octave + (rawLetter - letter) / 7
        var alteration = keyAlteration(forLetter: letter, keySig: keySig)
        for ref in MeasureAccidentalWalk.noteRefs(in: measure, division: division, measureDuration: measureDuration) {
            guard ref.tick < tick else { break }
            guard let earlier = MeasureAccidentalWalk.note(at: ref, in: measure.voices),
                  !AccidentalLineState.isUnwrittenTie(earlier),
                  let spelled = AccidentalLineState.spelling(pitch: earlier.pitch, tpc: earlier.tpc),
                  spelled.letter == letter, spelled.octave == octave
            else { continue }
            alteration = spelled.alteration
        }
        return (octave + 1) * 12 + AccidentalLineState.naturalSemitoneByLetter[letter] + alteration - note.pitch
    }
}
