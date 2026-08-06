import Foundation
@testable import SheetMusicCore

/// Programmatic score fixtures for the editing tests. Moved from Folino's `EditorFixtures` so both sides build the
/// same shapes — a fixture that drifts between the two repos would make an SP2 regression look like a port bug.
enum EditingFixtures {
    static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    /// One part, one staff, one measure of four quarter rests in 4/4.
    /// Voice elements: [0] timeSignature(4/4), [1..4] rest(quarter).
    static func fourQuarterRests() -> Score {
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
        ])
        let measure = Measure(voices: [voice])
        let staff = Staff(measures: [measure])
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])
        return Score(division: 480, parts: [part])
    }

    /// One part, one staff, two measures of four quarter rests, under a key signature of `concertKey`.
    ///
    /// Measure 0's voice elements: [0] keySignature, [1] timeSignature(4/4), [2...5] rest(quarter) — the key and the
    /// meter both belong to the first bar, so the rests start two slots in rather than one. Measure 1 carries
    /// neither, so its rests are [0...3].
    static func twoMeasuresOfQuarterRests(key concertKey: Int) -> Score {
        let firstVoice = Voice(elements: [
            .keySignature(KeySignature(concertKey: concertKey)),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
        ])
        let secondVoice = Voice(elements: [
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
        ])
        let staff = Staff(measures: [Measure(voices: [firstVoice]), Measure(voices: [secondVoice])])
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])
        return Score(division: 480, parts: [part])
    }

    /// One part, one staff, one measure that is a single full-measure
    /// rest in `numerator`/`denominator`. The staff's only voice has 2
    /// elements:
    ///   [0] timeSignature
    ///   [1] rest(.measure)
    ///
    /// This is what an empty bar looks like everywhere it is produced —
    /// what a parsed score carries, and what the editor writes back when
    /// a delete empties a bar.
    static func fullMeasureRest(
        numerator: Int = 4, denominator: Int = 4,
    ) -> Score {
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(
                numerator: numerator, denominator: denominator,
            )),
            .rest(duration: .measure),
        ])
        let measure = Measure(voices: [voice])
        let staff = Staff(measures: [measure])
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])
        return Score(division: 480, parts: [part])
    }

    /// Same, but element index 1 is a quarter chord on C4 (pitch 60, tpc 14).
    static func chordAtIndex1() -> Score {
        var score = fourQuarterRests()
        let id = VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        score[id] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        return score
    }

    /// Same, but element index 1 is a two-note quarter chord: C4 (pitch 60, tpc 14) + E4 (pitch 64, tpc 18).
    static func twoNoteChordAtIndex1() -> Score {
        var score = fourQuarterRests()
        let id = VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        score[id] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14), Note(pitch: 64, tpc: 18)]))
        return score
    }

    /// Element indices 1 and 2 are both quarter chords on C4 (pitch 60, tpc 14) — a same-pitch tie candidate pair.
    static func twoConsecutiveC4Chords() -> Score {
        var score = fourQuarterRests()
        let c4 = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        score[VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)] = .chord(c4)
        score[VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 2)] = .chord(c4)
        return score
    }

    /// Element index 1 is C4, element index 2 is D4 — same rhythm as `twoConsecutiveC4Chords`, but not a tie
    /// candidate (different pitch).
    static func c4ThenD4Chords() -> Score {
        var score = fourQuarterRests()
        score[VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)] =
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        score[VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 2)] =
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)]))
        return score
    }

    /// Two measures: measure 0's last quarter (element index 4) is C4; measure 1 opens with C4 — a cross-barline
    /// tie candidate.
    static func c4AcrossBarline() -> Score {
        var score = fourQuarterRests()
        let c4 = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        score[VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 4)] = .chord(c4)
        let secondMeasure = Measure(voices: [
            Voice(elements: [
                .chord(c4),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
            ]),
        ])
        score.parts[0].staves[0].measures.append(secondMeasure)
        return score
    }

    /// Two measures of four quarter rests in 4/4. Measure 0 keeps the fixture's leading time signature (so its rests
    /// start at element index 1); measure 1 carries none, so its first rest is element index 0 — the shape a real
    /// second measure has, and what the cross-barline paths have to walk into.
    static func twoMeasuresOfQuarterRests() -> Score {
        var score = fourQuarterRests()
        score.parts[0].staves[0].measures.append(Measure(voices: [
            Voice(elements: [
                .rest(duration: .quarter),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
            ]),
        ]))
        return score
    }

    /// `twoMeasuresOfQuarterRests` with a third measure, for chains that run past two bars.
    static func threeMeasuresOfQuarterRests() -> Score {
        var score = twoMeasuresOfQuarterRests()
        score.parts[0].staves[0].measures.append(Measure(voices: [
            Voice(elements: [
                .rest(duration: .quarter),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
            ]),
        ]))
        return score
    }

    static func restID(measure: Int = 0, element: Int) -> RestID {
        RestID(staff: staff0, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    static func noteID(measure: Int = 0, element: Int, noteIndex: Int = 0) -> NoteID {
        NoteID(
            staff: staff0,
            measureIndex: measure,
            voiceIndex: 0,
            elementIndex: element,
            noteIndexInChord: noteIndex,
        )
    }
}
