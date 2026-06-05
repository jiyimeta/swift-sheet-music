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
}
