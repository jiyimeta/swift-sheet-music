@testable import SheetMusicCore
import Testing

struct ScoreTransposeTests {
    // MARK: - transposedKey

    @Test func keyUpTwoSemitonesFromCgoesToDmajor() {
        #expect(Score.transposedKey(0, bySemitones: 2) == 2)
    }

    @Test func keyUpOneSemitonePrefersFlatEnharmonic() {
        #expect(Score.transposedKey(0, bySemitones: 1) == -5)
    }

    @Test func keyDownOneSemitonePrefersSharpEnharmonic() {
        #expect(Score.transposedKey(0, bySemitones: -1) == 5)
    }

    @Test func keyZeroDeltaIsIdentity() {
        #expect(Score.transposedKey(3, bySemitones: 0) == 3)
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

    @Test func transposeSpellsEachTieEndInItsOwnKey() {
        // D♮ (tpc 16, pitch 62) tied across a key change: measure 0 in D♭
        // major (key −5, where D♮ shows a natural), measure 1 in B♭ major
        // (key −2, where D♮ is diatonic / no accidental). Transposed +3,
        // each end is spelled in ITS OWN key, preserving its accidental
        // policy: origin → E♯ (tpc 25, sharp) in E major; continuation →
        // F♮ (tpc 13, no accidental) in D♭ major. The tpcs differ on
        // purpose — the layout pairs the tie by pitch, not spelling.
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
        // Origin: E♯ in E major — raised degree, accidental shown.
        #expect(note(measure: 0)?.pitch == 65)
        #expect(note(measure: 0)?.tpc == 25)
        #expect(note(measure: 0)?.accidental == .sharp)
        // Continuation: F♮ in D♭ major — diatonic, no accidental.
        #expect(note(measure: 1)?.pitch == 65)
        #expect(note(measure: 1)?.tpc == 13)
        #expect(note(measure: 1)?.accidental == nil)
    }
}
