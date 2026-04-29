import SheetMusicCore

enum EditingFixtures {
    /// One part, one staff, one measure of four quarter rests in 4/4.
    /// The staff's only voice has 5 elements:
    ///   [0] timeSignature(4/4)
    ///   [1] rest(quarter)
    ///   [2] rest(quarter)
    ///   [3] rest(quarter)
    ///   [4] rest(quarter)
    static func fourQuarterRests() -> Score {
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(Rest(duration: .quarter)),
            .rest(Rest(duration: .quarter)),
            .rest(Rest(duration: .quarter)),
            .rest(Rest(duration: .quarter)),
        ])
        let measure = Measure(voices: [voice])
        let staff = StaffContent(id: 1, measures: [measure])
        return Score(division: 480, parts: [], staves: [staff])
    }

    /// Same shape as `fourQuarterRests` but element index 1 is a
    /// quarter chord on C4 (pitch 60, tpc 14) instead of a rest.
    static func chordAtIndex1() -> Score {
        var score = fourQuarterRests()
        let chord = Chord(duration: .quarter,
                          notes: [Note(pitch: 60, tpc: 14)])
        let id = VoiceElementID(staffIndex: 0, measureIndex: 0,
                                voiceIndex: 0, elementIndex: 1)
        score[id] = .chord(chord)
        return score
    }
}
