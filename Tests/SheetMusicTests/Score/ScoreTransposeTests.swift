@testable import SheetMusicCore
import Testing

struct ScoreTransposeTests {
    // MARK: - respelledKey

    @Test func respelledKeyKeepsInRangeValues() {
        #expect(Score.respelledKey(3) == 3)
        #expect(Score.respelledKey(7) == 7) // C# major stays C# (not Db)
        #expect(Score.respelledKey(-7) == -7) // Cb major stays Cb
    }

    @Test func respelledKeyClampsOverflow() {
        #expect(Score.respelledKey(8) == -4) // 8 sharps → Ab major
        #expect(Score.respelledKey(-8) == 4) // 8 flats → E major
        #expect(Score.respelledKey(14) == 2) // → D major
    }

    // MARK: - transposed(bySemitones:)

    private func makeCMajorScore(
        useDrumset: Bool = false,
        group: String = "pitched",
    ) -> Score {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
        let voice = Voice(elements: [
            .keySignature(KeySignature(concertKey: 0)),
            .chord(chord),
        ])
        let staff = Staff(group: group, measures: [Measure(voices: [voice])])
        let inst = Instrument(id: "i", longName: "i", useDrumset: useDrumset)
        return Score(division: 480, parts: [
            Part(id: "p0", instrument: inst, staves: [staff]),
        ])
    }

    private func firstNote(_ score: Score) -> Note? {
        guard case let .chord(c) = score.parts[0].staves[0]
            .measures[0].voices[0].elements[1] else { return nil }
        return c.notes.first
    }

    private func firstKey(_ score: Score) -> Int? {
        guard case let .keySignature(k) = score.parts[0].staves[0]
            .measures[0].voices[0].elements[0] else { return nil }
        return k.concertKey
    }

    @Test func transposeZeroIsIdentity() {
        let score = makeCMajorScore()
        #expect(score.transposed(bySemitones: 0) == score)
    }

    @Test func transposeUpTwoShiftsPitchAndKey() {
        let out = makeCMajorScore().transposed(bySemitones: 2)
        #expect(firstNote(out)?.pitch == 62)
        #expect(firstKey(out) == 2)
    }

    @Test func transposeDownThreeShiftsPitch() {
        let out = makeCMajorScore().transposed(bySemitones: -3)
        #expect(firstNote(out)?.pitch == 57)
    }

    @Test func drumsetPartIsNotTransposed() {
        let out = makeCMajorScore(useDrumset: true).transposed(bySemitones: 2)
        #expect(firstNote(out)?.pitch == 60)
        #expect(firstKey(out) == 0)
    }

    @Test func percussionStaffIsNotTransposed() {
        let out = makeCMajorScore(group: "percussion").transposed(bySemitones: 5)
        #expect(firstNote(out)?.pitch == 60)
    }

    @Test func tickStructurePreservedSoCursorsStayValid() {
        let score = makeCMajorScore()
        let out = score.transposed(bySemitones: 4)
        #expect(
            out.parts[0].staves[0].measures[0].voices[0].elements.count
                == score.parts[0].staves[0].measures[0].voices[0].elements.count,
        )
    }

    @Test func transposePreservesChromaticSpellingRelativeToKey() {
        // B♭ (tpc 12, pitch 70) in G major (key +1), transposed +1 semitone.
        // The key becomes A♭ major (-4) and the note must stay a *lowered*
        // scale degree → C♭ (tpc 7, flat), NOT B♮ (tpc 13).
        let note = Note(pitch: 70, tpc: 12)
        let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
        let voice = Voice(elements: [
            .keySignature(KeySignature(concertKey: 1)),
            .chord(chord),
        ])
        let staff = Staff(group: "pitched", measures: [Measure(voices: [voice])])
        let inst = Instrument(id: "i", longName: "i")
        let score = Score(division: 480, parts: [
            Part(id: "p0", instrument: inst, staves: [staff]),
        ])
        let out = score.transposed(bySemitones: 1)
        guard case let .keySignature(k) = out.parts[0].staves[0]
            .measures[0].voices[0].elements[0],
            case let .chord(c) = out.parts[0].staves[0]
                .measures[0].voices[0].elements[1],
                let n = c.notes.first
        else {
            Issue.record("unexpected transposed structure")
            return
        }
        #expect(k.concertKey == -4) // A♭ major
        #expect(n.pitch == 71)
        #expect(n.tpc == 7) // C♭, not B♮ (tpc 13)
        #expect(n.accidental == .flat)
    }

    @Test func transposePreservesDoubleAlterationSpelling() {
        // A♭ (tpc 10, pitch 68) in G major (key +1), transposed +1 semitone.
        // It must stay a *doubly-lowered* scale degree → B𝄫 (tpc 5,
        // double-flat) in A♭ major, NOT A♮ (tpc 17).
        let note = Note(pitch: 68, tpc: 10)
        let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
        let voice = Voice(elements: [
            .keySignature(KeySignature(concertKey: 1)),
            .chord(chord),
        ])
        let staff = Staff(group: "pitched", measures: [Measure(voices: [voice])])
        let inst = Instrument(id: "i", longName: "i")
        let score = Score(division: 480, parts: [
            Part(id: "p0", instrument: inst, staves: [staff]),
        ])
        let out = score.transposed(bySemitones: 1)
        guard case let .chord(c) = out.parts[0].staves[0]
            .measures[0].voices[0].elements[1],
            let n = c.notes.first
        else {
            Issue.record("unexpected transposed structure")
            return
        }
        #expect(n.pitch == 69)
        #expect(n.tpc == 5) // B𝄫, not A♮ (tpc 17)
        #expect(n.accidental == .doubleFlat)
    }

    @Test func transposePreservesTieMetadata() {
        // A tie spanning a key change keeps its forward/back markers. Here
        // both sections stay in range under the chosen offset (D♭→E, B♭→C♯),
        // so the tied D♮ is spelled consistently as E♯ on both ends.
        let origin = Note(pitch: 62, tpc: 16, tieForward: 1)
        let cont = Note(pitch: 62, tpc: 16, tieBack: 1)
        let m0 = Measure(voices: [Voice(elements: [
            .keySignature(KeySignature(concertKey: -5)),
            .chord(Chord(duration: .quarter, notes: ChordNotes([origin]))),
        ])])
        let m1 = Measure(voices: [Voice(elements: [
            .keySignature(KeySignature(concertKey: -2)),
            .chord(Chord(duration: .quarter, notes: ChordNotes([cont]))),
        ])])
        let staff = Staff(group: "pitched", measures: [m0, m1])
        let inst = Instrument(id: "i", longName: "i")
        let score = Score(division: 480, parts: [
            Part(id: "p0", instrument: inst, staves: [staff]),
        ])
        let out = score.transposed(bySemitones: 3)
        func note(measure: Int) -> Note? {
            guard case let .chord(c) = out.parts[0].staves[0]
                .measures[measure].voices[0].elements[1] else { return nil }
            return c.notes.first
        }
        #expect(note(measure: 0)?.tieForward == 1)
        #expect(note(measure: 1)?.tieBack == 1)
        #expect(note(measure: 0)?.tpc == 25) // E♯
        #expect(note(measure: 1)?.tpc == 25) // E♯ (consistent)
    }

    // MARK: - modulation enharmonic-key selection

    /// Build a single-staff score from `(key, measureCount)` sections; each
    /// section opens with its key signature, every measure holds one note.
    private func makeModulatingScore(_ sections: [(key: Int, measures: Int)]) -> Score {
        var measures: [Measure] = []
        for section in sections {
            for index in 0 ..< section.measures {
                var elements: [VoiceElement] = []
                if index == 0 {
                    elements.append(.keySignature(KeySignature(concertKey: section.key)))
                }
                elements.append(.chord(Chord(
                    duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
                )))
                measures.append(Measure(voices: [Voice(elements: elements)]))
            }
        }
        let staff = Staff(group: "pitched", measures: measures)
        let inst = Instrument(id: "i", longName: "i")
        return Score(division: 480, parts: [Part(id: "p", instrument: inst, staves: [staff])])
    }

    private func keySignatures(_ score: Score) -> [Int] {
        var result: [Int] = []
        for measure in score.parts[0].staves[0].measures {
            for element in measure.voices[0].elements {
                if case let .keySignature(k) = element { result.append(k.concertKey) }
            }
        }
        return result
    }

    @Test func modulationDbBbBup3PrefersSharpForLongerKeys() {
        // Db(long)→Bb(med)→B(short), +3 → E→C#→D: the prominent Db & Bb
        // sections keep sharp spelling (E, C#); the brief B section is the
        // one forced to respell (D).
        let score = makeModulatingScore([(-5, 4), (-2, 2), (5, 1)])
        #expect(keySignatures(score.transposed(bySemitones: 3)) == [4, 7, 2])
    }

    @Test func modulationDbBbBup1SacrificesBriefKey() {
        let score = makeModulatingScore([(-5, 4), (-2, 2), (5, 1)])
        #expect(keySignatures(score.transposed(bySemitones: 1)) == [2, 5, 0]) // D, B, C
    }

    @Test func modulationCEbCdown1KeepsAllInRange() {
        let score = makeModulatingScore([(0, 2), (-3, 2), (0, 2)])
        #expect(keySignatures(score.transposed(bySemitones: -1)) == [5, 2, 5]) // B, D, B
    }

    @Test func modulationCCsharpUp1ChoosesFlatToStayInRange() {
        let score = makeModulatingScore([(0, 2), (7, 2)])
        #expect(keySignatures(score.transposed(bySemitones: 1)) == [-5, 2]) // Db, D
    }
}
