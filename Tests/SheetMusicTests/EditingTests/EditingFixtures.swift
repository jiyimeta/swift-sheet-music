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

    /// `length` consecutive C4 quarters starting at element index 1, joined into one tie chain, with the remaining
    /// slots left as rests. Element index `1 + length` is a plain C4 quarter that the chain does NOT reach — the
    /// neighbour a chain-wide edit must leave alone.
    static func tiedC4Chain(length: Int) -> Score {
        var score = fourQuarterRests()
        for offset in 0 ..< length {
            var note = Note(pitch: 60, tpc: 14)
            note.tieBack = offset > 0 ? 1 : nil
            note.tieForward = offset < length - 1 ? 1 : nil
            score[VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1 + offset)] =
                .chord(Chord(duration: .quarter, notes: [note]))
        }
        score[VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1 + length)] =
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
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

    /// `[ts 4/4, C4 e, D4 e, r q, r h]` — elements 1 and 2 are one beam group (both level 1, ticks 0 and 240 of
    /// beat 1), element 1 its leader. The remaining rests keep the bar full.
    static func twoBeamedEighths() -> Score {
        var score = fourQuarterRests()
        score.parts[0].staves[0].measures[0].voices[0] = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .eighth, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .eighth, notes: [Note(pitch: 62, tpc: 16)])),
            .rest(duration: .quarter),
            .rest(duration: .half),
        ])
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

    /// The replay fixture: three 4/4 measures under D major (F# and C#), on one staff, seeded with a mix of quarter
    /// rests and two chords so the script can reach every shape SP1 added — accidental repairs need a key signature
    /// AND a second note in the bar; the cross-bar planner needs a bar boundary to overrun; the collapse path needs
    /// a bar it can empty.
    ///
    /// Built from `twoMeasuresOfQuarterRests(key: 2)` (measure 0 keeps the key/time signature at elements 0/1, then
    /// four quarter rests at 2...5; measure 1 is four quarter rests at 0...3) plus a third measure of four more
    /// quarter rests, with two of those eleven rests overwritten as chords:
    /// - measure 0, element 2: C4 natural (pitch 60, tpc 14) — the "second note in the bar" the accidental-repair
    ///   steps need. It sits BEFORE the slot the script writes into (element 3), so writing there changes what
    ///   accidental state is already in force by the time the script's note is reached, and — since this seed's own
    ///   glyph was never computed by a repair pass (fixture construction doesn't run one) — the first edit that
    ///   touches this measure also fixes this note's glyph as a side effect, worth noting rather than fixing here.
    /// - measure 2, element 1: D4 (pitch 62, tpc 16) — the sole note in an otherwise fully-rested bar, so deleting
    ///   it empties the measure and exercises `FullMeasureRestCollapse`.
    ///
    /// Programmatic rather than a hand-written .mscx: the shape is reviewable in one screen and cannot drift from a
    /// file nobody reads. The DEVICE loads the MSCX encoding of this, recorded by `EditReplayGoldenTests`, so both
    /// sides start from identical bytes rather than from this builder and a file that agree only by inspection.
    static func replayFixture() -> Score {
        var score = twoMeasuresOfQuarterRests(key: 2)
        score.parts[0].staves[0].measures.append(Measure(voices: [
            Voice(elements: [
                .rest(duration: .quarter),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
            ]),
        ]))
        score[VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 2)] =
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        score[VoiceElementID(staff: staff0, measureIndex: 2, voiceIndex: 0, elementIndex: 1)] =
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)]))
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

    /// Two single-staff parts, four bars of 4/4, for the parity replay chain (spec 2026-09-02 §5). Staff (0,0):
    /// bar 0 = meter, C4, D4, two rests; bar 1 = four rests plus a second voice holding one measure rest; bar 2 =
    /// two tied half notes on E4; bar 3 = a measure rest. Staff (1,0) is measure rests throughout.
    static func parityFixture() -> Score {
        func chord(_ pitch: Int, _ tpc: Int, _ duration: NoteDuration, tieForward: Int? = nil, tieBack: Int? = nil)
            -> VoiceElement
        {
            var note = Note(pitch: pitch, tpc: tpc)
            note.tieForward = tieForward
            note.tieBack = tieBack
            return .chord(Chord(duration: duration, notes: [note]))
        }
        let flute = Staff(defaultClefType: "G", measures: [
            Measure(voices: [Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                chord(60, 14, .quarter), chord(62, 16, .quarter), .rest(duration: .quarter), .rest(duration: .quarter),
            ])]),
            Measure(voices: [
                Voice(elements: [
                    .rest(duration: .quarter), .rest(duration: .quarter),
                    .rest(duration: .quarter), .rest(duration: .quarter),
                ]),
                Voice(elements: [.rest(duration: .measure)]),
            ]),
            Measure(voices: [Voice(elements: [chord(64, 18, .half, tieForward: 1), chord(64, 18, .half, tieBack: 1)])]),
            Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
        ])
        let cello = Staff(defaultClefType: "F", measures: [
            Measure(voices: [Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)), .rest(duration: .measure),
            ])]),
            Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
            Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
            Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
        ])
        return Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [flute]),
            Part(id: "2", trackName: "Cello", instrument: Instrument(id: "cello"), staves: [cello]),
        ])
    }
}
